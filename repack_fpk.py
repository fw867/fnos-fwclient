"""把 fnpack 生成的 .fpk 重新打包，补回 Unix 可执行权限。

fnpack 会校验文件内容，但打包时不保留 mode 位（归档里都是 0666）。
fnOS 直接执行 cmd/ 下的生命周期脚本，缺少可执行位存在失败风险，
因此这里对 fnpack 的产物做一次无损重打包：

    1. 解出 fpk 顶层（app.tgz + cmd/ + config/ + wizard/ + manifest + 图标）
    2. cmd/* 设为 0755，其余保持 0644
    3. app.tgz 内部重新生成，bin/fwclient 与 server/fwclient-server 设为 0755
    4. 用确定性参数（固定 mtime/uid/gid）重新生成 gzip tar 并覆盖输出

用法：
    python repack_fpk.py <fnpack 产物路径> [输出路径]
"""
import gzip
import os
import shutil
import sys
import tarfile
import tempfile

CMD_MODE = 0o755
FILE_MODE = 0o644

# app.tgz 内部需要可执行权限的文件
EXEC_APP = (
    "bin/fwclient",
    "server/fwclient-server",
    "server/fwclient-server-arm64",
)


def extract_all(tar, dest):
    """兼容不同 Python 版本的解包（3.14 起需要显式 filter）。"""
    try:
        tar.extractall(dest, filter="fully_trusted")
    except TypeError:
        tar.extractall(dest)


def add_tree(tar, root, arc_prefix="", mode_for=None):
    """按固定顺序写入目录内容，并设置合理的 mode。

    Windows 上 os.chmod 无法设置可执行位，因此 mode 由 mode_for 显式决定，
    不依赖磁盘上的属性。
    """
    if mode_for is None:
        def mode_for(_arcname):
            return FILE_MODE

    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.join(rel_dir, name).replace(os.sep, "/")
            entries.append((rel, full))

    # 先写目录项，保证解包时顺序稳定
    written_dirs = set()
    for rel, _full in entries:
        parts = rel.split("/")[:-1]
        acc = ""
        for part in parts:
            acc = f"{acc}/{part}" if acc else part
            if acc in written_dirs:
                continue
            written_dirs.add(acc)
            info = tarfile.TarInfo(arc_prefix + acc)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.mtime = 0
            tar.addfile(info)

    for rel, full in entries:
        arcname = arc_prefix + rel
        info = tar.gettarinfo(full, arcname)
        info.mode = mode_for(arcname)
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = 0
        with open(full, "rb") as fh:
            tar.addfile(info, fh)


def repack(fpk_path, out_path):
    work = tempfile.mkdtemp(prefix="fpk-repack-")
    try:
        top = os.path.join(work, "top")
        os.makedirs(top, exist_ok=True)
        with tarfile.open(fpk_path, "r:gz") as tar:
            extract_all(tar, top)

        # 1) 解出 app.tgz
        app_dir = os.path.join(work, "app")
        os.makedirs(app_dir, exist_ok=True)
        with tarfile.open(os.path.join(top, "app.tgz"), "r:gz") as tar:
            extract_all(tar, app_dir)

        # 2) 重建 app.tgz。先写到树外再替换，避免重建顶层时读到写了一半的文件
        def app_mode(arcname):
            return CMD_MODE if arcname in EXEC_APP else FILE_MODE

        new_app_tgz = os.path.join(work, "app.tgz.new")
        with open(new_app_tgz, "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
                    add_tree(tar, app_dir, mode_for=app_mode)
        os.replace(new_app_tgz, os.path.join(top, "app.tgz"))

        # 3) 重建顶层归档
        def top_mode(arcname):
            return CMD_MODE if arcname.startswith("cmd/") else FILE_MODE

        with open(out_path, "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
                    add_tree(tar, top, mode_for=top_mode)

        return out_path
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src
    if os.path.abspath(src) == os.path.abspath(dst):
        tmp = src + ".repack"
        repack(src, tmp)
        os.replace(tmp, src)
        dst = src
    else:
        repack(src, dst)
    print(f"repacked: {dst} ({os.path.getsize(dst)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
