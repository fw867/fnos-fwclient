"""在没有 fnpack 的环境里，直接从应用目录打出可安装的 .fpk。

fnpack 的产物布局就是一个 tar.gz：

    manifest / ICON.PNG / ICON_256.PNG / app.tgz / cmd/ / config/ / wizard/

其中 app.tgz 是应用目录下 app/ 的 tar.gz。fnpack 打包时不保留 mode 位，
所以这里显式设置可执行位（cmd/* 与 app/bin/fwclient、app/server/fwclient-server），
规则与 repack_fpk.py 保持一致，产物可以直接喂给 fnOS 应用中心「手动安装」。

用法：
    python pack_fpk.py <应用目录> <输出 fpk>
"""
import gzip
import os
import shutil
import sys
import tarfile
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repack_fpk as rp  # noqa: E402  （复用同一套 mode 规则与归档写入逻辑）

# app.tgz 内部需要可执行权限的文件
EXEC_APP = rp.EXEC_APP
# 打进 fpk 顶层的文件与目录（backend/ 等源码不参与打包）
TOP_FILES = ("manifest", "ICON.PNG", "ICON_256.PNG")
TOP_DIRS = ("cmd", "config", "wizard")


def copy_text_lf(src, dst):
    """复制文本文件并去掉 CR，保证 Linux 下 shebang / 脚本可用。"""
    with open(src, "rb") as fh:
        data = fh.read()
    with open(dst, "wb") as fh:
        fh.write(data.replace(b"\r\n", b"\n").replace(b"\r", b"\n"))


def pack(app_dir, out_path):
    work = tempfile.mkdtemp(prefix="fpk-pack-")
    try:
        top = os.path.join(work, "top")
        os.makedirs(top, exist_ok=True)

        for name in TOP_FILES:
            src = os.path.join(app_dir, name)
            if not os.path.isfile(src):
                raise SystemExit(f"缺少文件：{src}")
            shutil.copy2(src, os.path.join(top, name))

        for name in TOP_DIRS:
            src = os.path.join(app_dir, name)
            if not os.path.isdir(src):
                raise SystemExit(f"缺少目录：{src}")
            dst = os.path.join(top, name)
            os.makedirs(dst, exist_ok=True)
            for entry in sorted(os.listdir(src)):
                s = os.path.join(src, entry)
                d = os.path.join(dst, entry)
                if os.path.isdir(s):
                    shutil.copytree(s, d)
                else:
                    copy_text_lf(s, d)

        # manifest 也统一成 LF，避免 fnOS 解析出多余的 CR
        copy_text_lf(os.path.join(app_dir, "manifest"), os.path.join(top, "manifest"))

        def app_mode(arcname):
            return rp.CMD_MODE if arcname in EXEC_APP else rp.FILE_MODE

        with open(os.path.join(top, "app.tgz"), "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
                    rp.add_tree(tar, os.path.join(app_dir, "app"), mode_for=app_mode)

        def top_mode(arcname):
            return rp.CMD_MODE if arcname.startswith("cmd/") else rp.FILE_MODE

        with open(out_path, "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
                    rp.add_tree(tar, top, mode_for=top_mode)

        return out_path
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    app_dir, out_path = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    pack(app_dir, out_path)
    print(f"packed: {out_path} ({os.path.getsize(out_path)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
