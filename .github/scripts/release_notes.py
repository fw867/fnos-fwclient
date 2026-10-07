"""从 manifest 的 changelog 字段生成 GitHub Release 说明。

manifest 里的 changelog 是一条长字符串，形如：

    changelog = 1.0.3：修复 A；修复 B。1.0.2：修复 C。

本脚本取出目标版本那一段，按「；」拆成条目，再补上安装说明与校验方式。

用法：
    python release_notes.py <manifest 路径> <版本号> > release-notes.md
"""
import re
import sys

INSTALL = """## 安装

1. 下载下方的 `fwclient-{ver}.fpk`；
2. 在 fnOS「应用中心 → 手动安装」中选择该文件；
3. 向导里填写网关域名与访问令牌（令牌留空表示不修改已保存的令牌）；
4. 桌面打开「内网穿透」即可查看状态与日志，并在需要时一键升级客户端。

升级安装会保留 `config.json` 与 `fwclient.id`，服务端不会把设备当成新机器。
"""

VERIFY = """## 校验

下载后可核对 `SHA256SUMS.txt`：

```bash
sha256sum -c SHA256SUMS.txt
```
"""


def read_changelog(manifest_text):
    m = re.search(r"^changelog\s*=\s*(.*)$", manifest_text, re.M)
    return m.group(1).strip() if m else ""


def section_for(changelog, version):
    """取出该版本的更新说明；找不到就退回整段 changelog。"""
    parts = re.split(r"(?=(?:\d+\.\d+\.\d+：))", changelog)
    for part in parts:
        if part.startswith(version + "："):
            return part[len(version) + 1:].strip()
    return changelog


def bullets(text):
    items = []
    for raw in re.split(r"[；;]", text):
        item = raw.strip().strip("。").strip()
        if item:
            items.append(item)
    return items


def build_notes(manifest_path, version):
    with open(manifest_path, encoding="utf-8") as fh:
        changelog = read_changelog(fh.read())

    lines = [f"## 内网穿透 v{version}", ""]
    items = bullets(section_for(changelog, version))
    if items:
        lines.append("### 更新内容")
        lines.append("")
        lines.extend(f"- {item}" for item in items)
        lines.append("")
    lines.append(INSTALL.format(ver=version).rstrip())
    lines.append("")
    lines.append(VERIFY.rstrip())
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    # 说明里全是中文：显式按 UTF-8 输出，避免在非 UTF-8 环境下写出乱码
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    sys.stdout.write(build_notes(sys.argv[1], sys.argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
