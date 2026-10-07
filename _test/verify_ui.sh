#!/usr/bin/env bash
# 验证管理页结构（直接取打包后端真实吐出的页面）：
#   - 「运行状态 / 应用配置」两个 tab，连接配置归到应用配置页
#   - 状态卡片里的按钮顺序是 启动 / 规范关闭 / 重启 / 检查并升级
#   - 「版本与升级」卡片、查询版本按钮、升级输出窗口都已移除
#   - app.js 里引用的每个元素 id 都真实存在（避免删卡片后前端报错）
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPK="${FPK:-$(ls -1t "$REPO"/dist/*.fpk 2>/dev/null | head -n 1)}"
[ -f "$FPK" ] || { echo "找不到 .fpk，请先执行 ./build.sh"; exit 1; }

WORK="$(mktemp -d /tmp/fwc-ui-XXXXXX)"
SRV_PID=""
RESULT=0
cleanup() {
    if [ -n "$SRV_PID" ]; then
        kill -9 "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$WORK/pkg/app"
tar -xzf "$FPK" -C "$WORK/pkg"
tar -xzf "$WORK/pkg/app.tgz" -C "$WORK/pkg/app"
chmod +x "$WORK/pkg/app/server/fwclient-server" 2>/dev/null

export TRIM_APPDEST="$WORK/pkg/app"
export TRIM_PKGETC="$WORK/etc"
export TRIM_PKGVAR="$WORK/var"
export TRIM_PKGTMP="$WORK/tmp"
export TRIM_SERVICE_PORT=18151
export FWCLIENT_BIND=127.0.0.1
mkdir -p "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"

echo "== 解包 .fpk：$(basename "$FPK")，启动管理后台端口 ${TRIM_SERVICE_PORT} =="
"$WORK/pkg/app/server/fwclient-server" >>"$TRIM_PKGVAR/backend.out" 2>&1 &
SRV_PID=$!

API="http://127.0.0.1:${TRIM_SERVICE_PORT}"
ready=0
for _ in $(seq 1 50); do
    if curl -sS -m 2 "$API/api/healthz" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.2
done
if [ "$ready" != "1" ]; then
    echo "  管理后台未就绪，输出如下："
    sed 's/^/    /' "$TRIM_PKGVAR/backend.out" 2>/dev/null
    exit 1
fi

curl -sS -m 8 "$API/" -o "$WORK/index.html"
curl -sS -m 8 "$API/app.js" -o "$WORK/app.js"
curl -sS -m 8 "$API/style.css" -o "$WORK/style.css"
for f in index.html app.js style.css; do
    [ -s "$WORK/$f" ] || { echo "  页面资源为空：$f"; exit 1; }
done

python3 - "$WORK/index.html" "$WORK/app.js" "$WORK/style.css" <<'PY'
import re
import sys
html_path, js_path, css_path = sys.argv[1:4]
html = open(html_path, encoding="utf-8").read()
js = open(js_path, encoding="utf-8").read()
css = open(css_path, encoding="utf-8").read()

pass_n = 0
fail_n = 0


def check(cond, msg):
    global pass_n, fail_n
    if cond:
        pass_n += 1
        print(f"  [PASS] {msg}")
    else:
        fail_n += 1
        print(f"  [FAIL] {msg}")


def slice_between(text, start_marker, end_marker=None):
    i = text.find(start_marker)
    if i < 0:
        return ""
    if end_marker is None:
        return text[i:]
    j = text.find(end_marker, i)
    return text[i:j] if j > 0 else text[i:]


tabs = re.findall(r'class="tab[^"]*"[^>]*data-panel="([^"]+)"', html)
check(tabs == ["panel-status", "panel-config"], f"两个 tab 顺序正确：{tabs}")
check('class="tabs"' in html, "存在 tab 导航容器")

status_panel = slice_between(html, 'id="panel-status"', 'id="panel-config"')
config_panel = slice_between(html, 'id="panel-config"', "</main>")

check('id="card-overview"' in status_panel, "运行状态页含「运行状态」卡片")
check('id="card-logs"' in status_panel, "运行状态页含「运行日志」卡片")
check('id="card-config"' in config_panel, "应用配置页含「连接配置」卡片")
check('id="card-appupdate"' in config_panel, "应用配置页含「应用更新」卡片")
for eid in ("in-gateway", "in-token", "in-autostart", "in-autoreconn", "in-verifytls", "btn-save"):
    check(f'id="{eid}"' in config_panel, f"连接配置元素在应用配置页：{eid}")
for eid in ("btn-app-check", "btn-app-upgrade", "v-app-cur", "v-app-latest", "app-update-notice"):
    check(f'id="{eid}"' in config_panel, f"应用更新元素在应用配置页：{eid}")

overview = slice_between(html, 'id="card-overview"', 'id="card-logs"')
order = [overview.find(f'id="{e}"') for e in ("btn-start", "btn-stop", "btn-restart", "btn-upgrade")]
check(all(i >= 0 for i in order), "状态卡片里四个按钮都存在")
check(order == sorted(order), "按钮顺序为 启动 / 规范关闭 / 重启 / 检查并升级")

check('id="card-upgrade"' not in html, "「版本与升级」卡片已移除")
check("btn-check-version" not in html, "「查询版本」按钮已移除")
check("upgrade-out" not in html, "升级输出窗口已移除")
check("btn-check-version" not in js, "app.js 不再引用「查询版本」按钮")
check("upgrade-out" not in js, "app.js 不再引用升级输出窗口")
check("btn-upgrade" in js, "app.js 仍绑定升级按钮")

ids = set(re.findall(r'id="([^"]+)"', html))
used = set(re.findall(r"\$\('([^']+)'\)", js)) | set(re.findall(r"getElementById\('([^']+)'\)", js))
missing = sorted(used - ids)
check(not missing, f"app.js 引用的元素都存在（缺失：{missing or '无'}）")

check(bool(re.search(r"\.tabs\s*\{", css)), "style.css 定义了 tab 样式")
check(bool(re.search(r"\.panel\[hidden\]", css)), "style.css 定义了页面隐藏规则")
check("stoppedByUser" in js, "前端展示「已手动停止」状态")

print()
print(f"== 结果: PASS={pass_n} FAIL={fail_n} ==")
sys.exit(0 if fail_n == 0 else 1)
PY

RESULT=$?
exit "$RESULT"
