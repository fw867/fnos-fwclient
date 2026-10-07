#!/usr/bin/env bash
# 在 WSL/Linux 下对打包内容做真机级静态验证（不依赖 fnOS）：
#   - 真实 fwclient 的 -v / -h / -k 行为
#   - 后端服务在 Linux 下的启动、接口、日志、启停
# 用法: bash _test/verify_linux.sh
set -uo pipefail

APP="/mnt/d/软件开发/fnos/fwclient-app"
WORK="$(mktemp -d /tmp/fwc-verify-XXXXXX)"
PASS=0
FAIL=0

ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "1" ]; then ok "$2"; else no "$2"; fi; }

echo "== 1) fwclient 二进制 =="
BIN="$APP/app/bin/fwclient"
[ -x "$BIN" ] && ok "可执行位正确" || no "缺少可执行位"
file -b "$BIN" 2>/dev/null | sed 's/^/  file: /'

VER="$("$BIN" -v 2>&1 | head -n 1)"
echo "  -v => $VER"
case "$VER" in
*fwclient\ v*) ok "-v 输出版本号" ;;
*) no "-v 输出异常" ;;
esac

"$BIN" -h >/dev/null 2>&1 && ok "-h 正常退出" || no "-h 返回非 0"

echo "== 2) fwclient 运行数据目录 =="
RUNDIR="$WORK/run"
mkdir -p "$RUNDIR"
"$BIN" -s 127.0.0.1 -t tk_verifytoken1234 -dir "$RUNDIR" -d >"$WORK/spawn.out" 2>&1
sleep 3
if [ -f "$RUNDIR/fwclient.pid" ] && kill -0 "$(cat "$RUNDIR/fwclient.pid")" 2>/dev/null; then
    ok "守护进程已启动 pid=$(cat "$RUNDIR/fwclient.pid")"
    echo "  日志文件: $(ls -l "$RUNDIR" | tr '\n' ' ')"
    echo "  --- 日志尾部 ---"
    tail -n 6 "$RUNDIR/fwclient.log" 2>/dev/null | sed 's/^/  /'
else
    no "守护进程未启动"
    sed 's/^/  spawn: /' "$WORK/spawn.out"
fi

if [ -f "$RUNDIR/fwclient.id" ]; then
    ok "设备标识已生成: $(head -c 40 "$RUNDIR/fwclient.id")"
else
    no "未生成设备标识"
fi

"$BIN" -k -dir "$RUNDIR" >"$WORK/kill.out" 2>&1
sleep 2
if [ -f "$RUNDIR/fwclient.pid" ] && kill -0 "$(cat "$RUNDIR/fwclient.pid")" 2>/dev/null; then
    no "-k 未能关闭客户端"
    kill -9 "$(cat "$RUNDIR/fwclient.pid")" 2>/dev/null
else
    ok "-k 规范关闭成功 ($(tr -d '\n' <"$WORK/kill.out"))"
fi

echo "== 3) 后端服务 =="
SRV="$APP/app/server/fwclient-server"
[ -x "$SRV" ] && ok "backend 可执行位正确" || no "backend 缺少可执行位"

export TRIM_APPDEST="$APP/app"
export TRIM_PKGETC="$WORK/etc"
export TRIM_PKGVAR="$WORK/var"
export TRIM_PKGTMP="$WORK/tmp"
export TRIM_SERVICE_PORT=18123
export FWCLIENT_BIND=127.0.0.1
export FWCLIENT_BIN="$BIN"
mkdir -p "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"

cat >"$TRIM_PKGETC/config.json" <<EOF
{
  "gateway": "127.0.0.1",
  "token": "tk_verifytoken1234",
  "insecure": true,
  "autoStart": true,
  "autoReconn": true
}
EOF

"$SRV" >"$TRIM_PKGVAR/stdout.log" 2>&1 &
SRV_PID=$!
sleep 3

if kill -0 "$SRV_PID" 2>/dev/null; then
    ok "后端进程存活 (pid=$SRV_PID)"
else
    no "后端进程已退出"
    sed 's/^/  /' "$TRIM_PKGVAR/backend.log" 2>/dev/null
fi

api() { curl -sS -m 10 "$@" 2>/dev/null; }

HEALTH="$(api "http://127.0.0.1:18123/api/healthz")"
echo "  healthz => $HEALTH"
case "$HEALTH" in
*'"code":0'*) ok "健康检查通过" ;;
*) no "健康检查失败" ;;
esac

IDX="$(api -o /dev/null -w '%{http_code}' "http://127.0.0.1:18123/")"
check "$([ "$IDX" = "200" ] && echo 1 || echo 0)" "管理页面返回 200 (实际 $IDX)"
CSS="$(api -o /dev/null -w '%{http_code}' "http://127.0.0.1:18123/style.css")"
check "$([ "$CSS" = "200" ] && echo 1 || echo 0)" "静态资源 style.css 返回 200 (实际 $CSS)"

STATUS="$(api "http://127.0.0.1:18123/api/status")"
echo "  status => $(echo "$STATUS" | head -c 400)"
case "$STATUS" in
*'"fwVersion":"fwclient v1.3.90'*) ok "版本号读取正确" ;;
*) no "版本号读取异常" ;;
esac
case "$STATUS" in
*'"running":true'*) ok "客户端已按配置自动连接" ;;
*) no "客户端未自动连接" ;;
esac

sleep 3
LOGS="$(api "http://127.0.0.1:18123/api/logs?lines=50")"
case "$LOGS" in
*'CONNECT :443'* | *'fwclient'*) ok "日志接口有内容" ;;
*) no "日志接口为空: $(echo "$LOGS" | head -c 200)" ;;
esac
echo "  --- 后台日志尾部 ---"
tail -n 8 "$TRIM_PKGVAR/backend.log" 2>/dev/null | sed 's/^/  /'

STOP="$(api -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:18123/api/stop")"
echo "  stop => $STOP"
case "$STOP" in
*'"code":0'*) ok "停止接口返回成功" ;;
*) no "停止接口异常" ;;
esac

START="$(api -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:18123/api/start")"
echo "  start => $START"
case "$START" in
*'"code":0'*) ok "启动接口返回成功" ;;
*) no "启动接口异常" ;;
esac

BAD="$(api -X POST -H 'Content-Type: application/json' -d '{"gateway":"bad domain; rm -rf /"}' "http://127.0.0.1:18123/api/config")"
echo "  bad gateway => $BAD"
case "$BAD" in
*'"code":1'*) ok "非法网关域名被拒绝" ;;
*) no "非法网关域名未被拒绝" ;;
esac

api -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:18123/api/stop" >/dev/null
kill -TERM "$SRV_PID" 2>/dev/null
sleep 1
kill -9 "$SRV_PID" 2>/dev/null
rm -rf "$WORK"

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
