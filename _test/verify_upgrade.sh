#!/usr/bin/env bash
# 覆盖升级验证：应用中心「上传应用包升级」后，页面必须还能打开。
#   1) 正常升级：旧包 upgrade_init → 替换文件 → 新包 upgrade_init/callback
#   2) 旧后端残留在跑、pid 文件已失效（最常见的「升级后空白页」成因）
#   3) 升级复制不完整，新后端二进制被截成 0 字节
# 三种情况都要求：升级后只剩一个后端进程、healthz 报告新版本、首页返回 200。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD_FPK="${OLD_FPK:-$REPO/dist/fwclient-1.0.2.fpk}"
NEW_FPK="${NEW_FPK:-$(ls -1t "$REPO"/dist/*.fpk 2>/dev/null | head -n 1)}"
[ -f "$OLD_FPK" ] || { echo "缺少旧版本包（默认 dist/fwclient-1.0.2.fpk）：$OLD_FPK"; exit 1; }
[ -f "$NEW_FPK" ] || { echo "缺少新版本包，请先执行 ./build.sh"; exit 1; }

PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "1" ]; then ok "$2"; else no "$2"; fi; }

PORT_BASE=18211

# run_case <名称> <场景> <端口>
run_case() {
    local title="$1" case_kind="$2" port="$3"
    local W OLD_CMD NEW_CMD
    W="$(mktemp -d /tmp/fwc-upgrade-XXXX)"
    export TRIM_APPNAME=fwclient
    export TRIM_USERNAME="$(id -un)" TRIM_GROUPNAME="$(id -gn)"
    export TRIM_APPDEST="$W/app" TRIM_PKGETC="$W/etc" TRIM_PKGVAR="$W/var" TRIM_PKGTMP="$W/tmp"
    export TRIM_SERVICE_PORT="$port" FWCLIENT_BIND=127.0.0.1 TRIM_TEMP_LOGFILE="$W/user-visible.log"
    mkdir -p "$TRIM_APPDEST" "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"

    mkdir -p "$W/old/app" "$W/new/app"
    tar -xzf "$OLD_FPK" -C "$W/old"; tar -xzf "$W/old/app.tgz" -C "$W/old/app"
    tar -xzf "$NEW_FPK" -C "$W/new"; tar -xzf "$W/new/app.tgz" -C "$W/new/app"
    local d f
    for d in "$W/old/cmd" "$W/new/cmd"; do
        for f in "$d"/*; do sed -i 's/\r$//' "$f"; done
        chmod +x "$d"/*
    done
    OLD_CMD="$W/old/cmd"; NEW_CMD="$W/new/cmd"
    # 模拟 fnOS 把新包解到临时目录，升级回调可据此刷新程序文件
    cp -r "$W/new/app/." "$TRIM_PKGTMP/"
    NEW_VER="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "$W/new/manifest" | head -n 1 | tr -d '[:space:]')"

    printf '\n== %s ==\n' "$title"

    # 装旧版本并跑起来
    cp -r "$W/old/app/." "$TRIM_APPDEST/"
    wizard_gateway=127.0.0.1 wizard_token=tk_upgradetest1234 wizard_insecure=true \
        TRIM_APP_STATUS=INSTALL TRIM_APPVER=1.0.0 bash "$OLD_CMD/install_callback" >/dev/null 2>&1
    TRIM_APP_STATUS=START TRIM_APPVER=1.0.0 bash "$OLD_CMD/main" start >/dev/null 2>&1
    sleep 3

    case "$case_kind" in
    normal)
        TRIM_APP_STATUS=UPGRADE TRIM_OLD_APPVER=1.0.0 TRIM_APPVER="$NEW_VER" bash "$OLD_CMD/upgrade_init" >/dev/null 2>&1
        ;;
    stale)
        # 应用中心直接杀进程升级：后端还在，但 pid 文件没了
        rm -f "$TRIM_PKGVAR/backend.pid" "$TRIM_PKGVAR/run/fwclient.pid"
        ;;
    corrupt)
        TRIM_APP_STATUS=UPGRADE TRIM_OLD_APPVER=1.0.0 TRIM_APPVER="$NEW_VER" bash "$NEW_CMD/upgrade_init" >/dev/null 2>&1
        ;;
    esac

    # 应用中心替换文件
    cp -r "$W/new/app/." "$TRIM_APPDEST/" 2>/dev/null || true
    if [ "$case_kind" = "corrupt" ]; then
        : > "$TRIM_APPDEST/server/fwclient-server"
    fi

    TRIM_APP_STATUS=UPGRADE TRIM_OLD_APPVER=1.0.0 TRIM_APPVER="$NEW_VER" bash "$NEW_CMD/upgrade_init" >/dev/null 2>&1
    TRIM_APP_STATUS=UPGRADE TRIM_OLD_APPVER=1.0.0 TRIM_APPVER="$NEW_VER" bash "$NEW_CMD/upgrade_callback" >/dev/null 2>&1
    sleep 3

    local health page n
    health="$(curl -sS -m 5 "http://127.0.0.1:${port}/api/healthz" 2>/dev/null)"
    page="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)"
    n="$(pgrep -f "$TRIM_APPDEST/server/fwclient-server" 2>/dev/null | wc -l | tr -d ' ')"

    check "$([ "$n" = "1" ] && echo 1 || echo 0)" "升级后只有 1 个后端进程（实际 ${n}）"
    case "$health" in
    *"\"version\":\"${NEW_VER}\""*) ok "healthz 报告新版本 ${NEW_VER}" ;;
    *) no "healthz 版本不对：${health:-无响应}" ;;
    esac
    check "$([ "$page" = "200" ] && echo 1 || echo 0)" "管理页可打开（HTTP ${page:-失败}）"

    if [ "$case_kind" = "stale" ]; then
        case "$(cat "$TRIM_PKGVAR/lifecycle.log" 2>/dev/null)" in
        *清理残留的管理后台进程*) ok "识别并清理了残留的旧后端进程" ;;
        *) no "没有清理残留后端进程" ;;
        esac
    fi
    if [ "$case_kind" = "corrupt" ]; then
        case "$(cat "$TRIM_PKGVAR/lifecycle.log" 2>/dev/null)" in
        *为空或残缺*) ok "识别出残缺的后端程序并尝试修复" ;;
        *) no "没有识别出残缺的后端程序" ;;
        esac
        check "$([ -s "$TRIM_APPDEST/server/fwclient-server" ] && echo 1 || echo 0)" "后端程序已修复为非空文件"
    fi

    pkill -f "$TRIM_APPDEST" 2>/dev/null
    rm -rf "$W"
}

echo "== 覆盖升级验证：旧包 $(basename "$OLD_FPK") → 新包 $(basename "$NEW_FPK") =="
run_case "1) 正常覆盖升级" normal $((PORT_BASE))
run_case "2) 旧后端残留 + pid 文件失效" stale $((PORT_BASE + 1))
run_case "3) 升级复制不完整（后端二进制 0 字节）" corrupt $((PORT_BASE + 2))

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
