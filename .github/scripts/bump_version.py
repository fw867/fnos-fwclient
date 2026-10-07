"""发布时自动累加版本号，并把提交信息写成新版本的更新说明。

做三件事：
  1. `fwclient-app/manifest` 的 version 补丁号 +1（1.0.3 → 1.0.4）；
  2. 用提交信息（或手动触发的说明）生成 changelog 条目插到最前面，
     只保留最近 `--keep` 个版本，避免 manifest 无限变长；
  3. 同步 `fwclient-app/backend/main.go` 里的 appVersion 常量——
     管理后台自报版本必须与 manifest 一致，否则页面页脚会对不上。

用法：
    python bump_version.py --manifest <manifest> --main-go <main.go> \\
        --notes-file <提交信息文件> [--keep 6] [--github-output <文件>]
"""
import argparse
import os
import re
import sys

MARKERS = ("[release]", "[skip ci]", "[skip-ci]")


def parse_version(text):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text.strip())
    if not m:
        raise SystemExit(f"版本号格式不正确：{text!r}（应为 X.Y.Z）")
    return tuple(int(x) for x in m.groups())


def next_patch(version):
    major, minor, patch = parse_version(version)
    return f"{major}.{minor}.{patch + 1}"


def strip_markers(text):
    out = text
    for marker in MARKERS:
        out = out.replace(marker, " ")
    return out


def notes_to_items(notes):
    """把提交信息整理成条目列表：正文优先，没有正文就用标题。"""
    lines = [strip_markers(line).strip() for line in notes.splitlines()]
    lines = [line for line in lines if line]
    if not lines:
        return ["自动发布"]

    subject = lines[0]
    body = []
    for line in lines[1:]:
        low = line.lower()
        if low.startswith(("signed-off-by:", "co-authored-by:", "reviewed-by:", "#")):
            continue
        line = re.sub(r"^[-*•]\s*", "", line)
        line = line.strip()
        if line:
            body.append(line.rstrip("。"))

    items = body if body else [subject.rstrip("。")]
    return items


def changelog_entry(version, items):
    return f"{version}：" + "；".join(items) + "。"


def update_manifest(text, version, entry, keep):
    m = re.search(r"^(version[ \t]*=[ \t]*)(\S+)[ \t]*$", text, re.M)
    if not m:
        raise SystemExit("manifest 里找不到 version 字段")
    previous = m.group(2)
    text = text[: m.start(2)] + version + text[m.end(2):]

    mc = re.search(r"^(changelog[ \t]*=[ \t]*)(.*)$", text, re.M)
    if not mc:
        raise SystemExit("manifest 里找不到 changelog 字段")
    old = mc.group(2).strip()
    parts = [p for p in re.split(r"(?=(?:\d+\.\d+\.\d+：))", old) if p.strip()]
    merged = entry + "".join(parts[: max(0, keep - 1)])
    text = text[: mc.start(2)] + merged + text[mc.end(2):]
    return text, previous


def update_main_go(text, version):
    # 注意 const 块里的行首有制表符，必须允许前导空白
    m = re.search(r'^([ \t]*appVersion[ \t]*=[ \t]*")([^"]*)(")', text, re.M)
    if not m:
        raise SystemExit("backend/main.go 里找不到 appVersion 常量，无法同步版本号")
    previous = m.group(2)
    text = text[: m.start(2)] + version + text[m.end(2):]
    return text, previous


def emit(path, values):
    lines = [f"{k}={v}" for k, v in values.items()]
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--main-go", required=True)
    ap.add_argument("--notes-file", default="")
    ap.add_argument("--keep", type=int, default=6)
    ap.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    args = ap.parse_args()

    manifest = open(args.manifest, encoding="utf-8").read()
    main_go = open(args.main_go, encoding="utf-8").read()
    notes = open(args.notes_file, encoding="utf-8").read() if args.notes_file else ""

    current = re.search(r"^version[ \t]*=[ \t]*(\S+)[ \t]*$", manifest, re.M)
    if not current:
        raise SystemExit("manifest 里找不到 version 字段")
    version = next_patch(current.group(1))

    items = notes_to_items(notes)
    entry = changelog_entry(version, items)
    manifest, previous = update_manifest(manifest, version, entry, args.keep)
    main_go, go_previous = update_main_go(main_go, version)

    with open(args.manifest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(manifest)
    with open(args.main_go, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(main_go)

    emit(args.github_output, {"version": version, "previous": previous})

    print(f"版本号：{previous} -> {version}")
    print(f"main.go appVersion：{go_previous} -> {version}")
    print("更新说明：")
    for item in items:
        print(f"  - {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
