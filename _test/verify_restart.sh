#!/usr/bin/env bash
# 复查：反复 restart 不产生孤儿进程、停止/启动可用、规范关闭生效
set -uo pipefail

FPK="/mnt/d/软件开发/fnos/dist/fwclient-1.0.2.fpk"
WORK="$(mktemp -d /tmp/fwc-extra-XXXXXX)"
PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "1" ]; then ok "$2"; else no "$2"; fi; }

mkdir -p "$WORK/pkg" "$WORK/pkg/app"
tar -xzf "$FPK" -C "$WORK/pkg"
tar -xzf "$WORK/pkg/app.tgz" -C "$WORK/pkg/app"

export TRIM_APPDEST="$WORK/pkg/app" TRIM_PKGETC="$WORK/etc" TRIM_PKGVAR="$WORK/var" TRIM_PKGTMP="$WORK/tmp"
export TRIM_SERVICE_PORT=18131 FWCLIENT_BIND=127.0.0.1
mkdir -p "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"
cat >"$TRIM_PKGETC/config.json" <<EOF
{"gateway":"127.0.0.1","token":"tk_extra_test_1234","insecure":true,"autoStart":true,"autoReconn":true}
EOF

PIDF="$TRIM_PKGVAR/run/fwclient.pid"
"$TRIM_APPDEST/server/fwclient-server" >>"$TRIM_PKGVAR/stdout.log" 2>&1 &
SRV=$!
sleep 3

procs() { pgrep -f 'pkg/app/bin/fwclient' 2>/dev/null | wc -l | tr -d ' '; }

echo "== 连续 4 次 restart =="
MAXT=0
for i in 1 2 3 4; do
    T0=$(date +%s.%N)
    R="$(curl -sS -m 25 -X POST -H 'Content-Type: application/json' -d '{}' \
        "http://127.0.0.1:18131/api/restart" -w '|%{http_code}')"
    T1=$(date +%s.%N)
    D="$(echo "$T1 - $T0" | bc)"
    N="$(procs)"
    echo "  #$i 用时=${D}s 守护进程数=$N $R"
    case "$R" in
    *'"code":0'*'|200') : ;;
    *) no "restart#$i 返回异常" ;;
    esac
    check "$([ "$N" = "1" ] && echo 1 || echo 0)" "restart#$i 后仅有 1 个守护进程"
    MAXT=$(echo "if ($D > $MAXT) $D else $MAXT" | bc)
done
check "$(echo "$MAXT < 3" | bc)" "单次 restart 耗时 ${MAXT}s（< 3s，说明走了规范关闭）"

echo "== status =="
S="$(curl -sS -m 8 "http://127.0.0.1:18131/api/status")"
case "$S" in
*'"running":true'*) ok "状态为运行中" ;;
*) no "状态异常" ;;
esac
check "$([ -f "$PIDF" ] && echo 1 || echo 0)" "pid 文件存在"

echo "== stop =="
R="$(curl -sS -m 25 -X POST -d '{}' -H 'Content-Type: application/json' "http://127.0.0.1:18131/api/stop")"
echo "  $R"
case "$R" in
*'规范关闭'*) ok "停止走了规范关闭流程" ;;
*) no "停止未走规范关闭流程：$R" ;;
esac
sleep 1
ALL="$(procs)"
if [ "$ALL" = "0" ]; then
    ok "stop 后无残留守护进程"
else
    no "stop 后无残留守护进程（$ALL 个）"
    echo "  --- 残留进程详情 ---"
    ps -eo pid,ppid,args | grep 'app/bin/fwclient' | grep -v grep | sed 's/^/    /'
    echo "  --- backend.log ---"
    tail -n 12 "$TRIM_PKGVAR/backend.log" | sed 's/^/    /'
    echo "  --- stop 接口输出 ---"
    echo "    $R"
fi

echo "== start =="
R="$(curl -sS -m 25 -X POST -d '{}' -H 'Content-Type: application/json' "http://127.0.0.1:18131/api/start")"
sleep 2
case "$R" in
*'"code":0'*) ok "启动接口成功" ;;
*) no "启动接口异常：$R" ;;
esac
check "$([ "$(procs)" = "1" ] && echo 1 || echo 0)" "start 后有 1 个守护进程"

echo "== 清理 =="
curl -sS -m 25 -X POST -d '{}' -H 'Content-Type: application/json' "http://127.0.0.1:18131/api/stop" >/dev/null 2>&1
kill -9 "$SRV" 2>/dev/null
pkill -f 'pkg/app/bin/fwclient' 2>/dev/null
rm -rf "$WORK"

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
