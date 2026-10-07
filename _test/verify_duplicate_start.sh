#!/usr/bin/env bash
# 验证「启动只拉起一个客户端进程」这条修复：
#   1) cmd/main start 重复执行、以及与后端自启动并发时，fwclient 只应有一个守护进程
#   2) 后端自启动/页面启动都要带上 -insecure（与管理后台配置一致）
#   3) 历史遗留的重复进程在再次启动、停止、重启时都会被收敛清理
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPK="${FPK:-$(ls -1t "$REPO"/dist/*.fpk 2>/dev/null | head -n 1)}"
[ -f "$FPK" ] || { echo "找不到 .fpk，请先执行 ./build.sh"; exit 1; }

WORK="$(mktemp -d /tmp/fwc-dup-XXXXXX)"
PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "1" ]; then ok "$2"; else no "$2"; fi; }

echo "== 解包 .fpk：$(basename "$FPK") =="
mkdir -p "$WORK/pkg/app"
tar -xzf "$FPK" -C "$WORK/pkg"
tar -xzf "$WORK/pkg/app.tgz" -C "$WORK/pkg/app"

# 打包后的脚本应为 LF；工作区可能是 CRLF，这里兜底
for f in "$WORK"/pkg/cmd/*; do sed -i 's/\r$//' "$f"; done
chmod +x "$WORK"/pkg/cmd/* "$WORK/pkg/app/bin/fwclient" "$WORK/pkg/app/server/fwclient-server" 2>/dev/null

export TRIM_APPNAME=fwclient
export TRIM_APPVER=1.0.3
export TRIM_USERNAME="$(id -un)"
export TRIM_GROUPNAME="$(id -gn)"
export TRIM_APPDEST="$WORK/pkg/app"
export TRIM_PKGETC="$WORK/etc"
export TRIM_PKGVAR="$WORK/var"
export TRIM_PKGTMP="$WORK/tmp"
export TRIM_SERVICE_PORT=18141
export TRIM_TEMP_LOGFILE="$WORK/user-visible.log"
mkdir -p "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"
printf '{"gateway":"127.0.0.1","token":"tk_duplicate_test1234","insecure":true,"autoStart":true,"autoReconn":true}\n' \
    > "$TRIM_PKGETC/config.json"

CMD="$WORK/pkg/cmd"
BIN="$TRIM_APPDEST/bin/fwclient"
PIDF="$TRIM_PKGVAR/run/fwclient.pid"
API="http://127.0.0.1:$TRIM_SERVICE_PORT"

procs() { pgrep -f "$BIN" 2>/dev/null | wc -l | tr -d ' '; }
start_app() { TRIM_APP_STATUS=START "$CMD/main" start >/dev/null 2>&1; }
stop_app() { TRIM_APP_STATUS=STOP "$CMD/main" stop >/dev/null 2>&1; }
cleanup() {
    stop_app
    pkill -f "$BIN" 2>/dev/null
    pkill -f "$TRIM_APPDEST/server/fwclient-server" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1) 连续 4 次「启动应用」，每次都应只剩 1 个客户端进程 =="
for i in 1 2 3 4; do
    start_app
    sleep 3
    N="$(procs)"
    check "$([ "$N" = "1" ] && echo 1 || echo 0)" "第 $i 次启动后客户端进程数=${N}"
    if [ "$i" = "1" ]; then
        # 已在运行时重复调用 start，不应再多拉起一个
        start_app
        sleep 2
        N="$(procs)"
        check "$([ "$N" = "1" ] && echo 1 || echo 0)" "运行中重复执行 start 后客户端进程数=${N}"
        CMDLINE="$(tr '\0' ' ' < "/proc/$(cat "$PIDF" 2>/dev/null)/cmdline" 2>/dev/null)"
        case "$CMDLINE" in
        *"-insecure"*) ok "启动参数带 -insecure（配置 insecure=true）" ;;
        *) no "启动参数缺少 -insecure：${CMDLINE}" ;;
        esac
    fi
    stop_app
    sleep 2
    N="$(procs)"
    check "$([ "$N" = "0" ] && echo 1 || echo 0)" "第 $i 次停止后残留进程数=${N}"
done

echo "== 2) 历史遗留的重复进程：再次启动时收敛为 1 个 =="
start_app
sleep 3
# 人为制造重复：并发拉起两个守护进程（旧版本「脚本 + 后端」竞态就是这个效果）
"$BIN" -s 127.0.0.1 -t tk_duplicate_test1234 -dir "$TRIM_PKGVAR/run" -d >/dev/null 2>&1 &
"$BIN" -s 127.0.0.1 -t tk_duplicate_test1234 -dir "$TRIM_PKGVAR/run" -d >/dev/null 2>&1 &
wait
sleep 3
N="$(procs)"
check "$([ "$N" -ge "2" ] && echo 1 || echo 0)" "已人为制造重复进程（当前 ${N} 个）"
start_app
sleep 3
N="$(procs)"
check "$([ "$N" = "1" ] && echo 1 || echo 0)" "再次启动后收敛为 1 个（当前 ${N} 个）"

echo "== 3) 通过管理后台接口启动时也要收敛重复进程 =="
"$BIN" -s 127.0.0.1 -t tk_duplicate_test1234 -dir "$TRIM_PKGVAR/run" -d >/dev/null 2>&1 &
"$BIN" -s 127.0.0.1 -t tk_duplicate_test1234 -dir "$TRIM_PKGVAR/run" -d >/dev/null 2>&1 &
wait
sleep 3
N="$(procs)"
check "$([ "$N" -ge "2" ] && echo 1 || echo 0)" "再次人为制造重复进程（当前 ${N} 个）"
curl -sS -m 25 -X POST -d '{}' -H 'Content-Type: application/json' "$API/api/start" >/dev/null 2>&1
sleep 3
N="$(procs)"
check "$([ "$N" = "1" ] && echo 1 || echo 0)" "接口启动后收敛为 1 个（当前 ${N} 个）"

echo "== 4) 重启接口不产生孤儿进程 =="
curl -sS -m 25 -X POST -d '{}' -H 'Content-Type: application/json' "$API/api/restart" >/dev/null 2>&1
sleep 4
N="$(procs)"
check "$([ "$N" = "1" ] && echo 1 || echo 0)" "restart 后客户端进程数=${N}"

echo "== 5) 停止后 pid 文件与进程都应清空，并记录「手动停止」 =="
curl -sS -m 25 -X POST -d '{}' -H 'Content-Type: application/json' "$API/api/stop" >/dev/null 2>&1
sleep 2
N="$(procs)"
check "$([ "$N" = "0" ] && echo 1 || echo 0)" "接口停止后残留进程数=${N}"
check "$([ ! -f "$PIDF" ] && echo 1 || echo 0)" "pid 文件已清理"
check "$([ -f "$TRIM_PKGVAR/client.stopped" ] && echo 1 || echo 0)" "已写入「手动停止」标记"
S="$(curl -sS -m 8 "$API/api/status")"
case "$S" in
*'"stoppedByUser":true'*) ok "状态接口报告 stoppedByUser=true（看护线程不会自动拉起）" ;;
*) no "状态接口未报告手动停止：$(echo "$S" | head -c 200)" ;;
esac

echo "== 6) 应用启动会清掉「手动停止」标记并重新连接 =="
start_app
sleep 3
N="$(procs)"
check "$([ "$N" = "1" ] && echo 1 || echo 0)" "启动后客户端进程数=${N}"
check "$([ ! -f "$TRIM_PKGVAR/client.stopped" ] && echo 1 || echo 0)" "「手动停止」标记已清除"
S="$(curl -sS -m 8 "$API/api/status")"
case "$S" in
*'"stoppedByUser":false'*) ok "状态接口报告 stoppedByUser=false" ;;
*) no "状态接口仍未清除手动停止：$(echo "$S" | head -c 200)" ;;
esac

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
