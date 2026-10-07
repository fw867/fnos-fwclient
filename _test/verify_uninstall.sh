#!/usr/bin/env bash
# 卸载流程验证：保留/清理设备标识两种分支
set -uo pipefail

FPK="/mnt/d/软件开发/fnos/dist/fwclient-1.0.2.fpk"
WORK="$(mktemp -d /tmp/fwc-uninst-XXXXXX)"
mkdir -p "$WORK/pkg" "$WORK/pkg/app"
tar -xzf "$FPK" -C "$WORK/pkg"
tar -xzf "$WORK/pkg/app.tgz" -C "$WORK/pkg/app"

export TRIM_APPDEST="$WORK/pkg/app" TRIM_PKGETC="$WORK/etc" TRIM_PKGVAR="$WORK/var" TRIM_PKGTMP="$WORK/tmp"
export TRIM_SERVICE_PORT=18136 FWCLIENT_BIND=127.0.0.1
export TRIM_TEMP_LOGFILE="$WORK/user-visible.log"
export TRIM_USERNAME="$(id -un)" TRIM_GROUPNAME="$(id -gn)" TRIM_APPVER=1.0.0
mkdir -p "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"
cat >"$TRIM_PKGETC/config.json" <<EOF
{"gateway":"127.0.0.1","token":"tk_uninst_test_1234","insecure":true,"autoStart":true,"autoReconn":true}
EOF

CMD="$WORK/pkg/cmd"; chmod +x "$CMD"/*
PIDF="$TRIM_PKGVAR/run/fwclient.pid"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 启动服务 =="
TRIM_APP_STATUS=START "$CMD/main" start
sleep 3
[ -f "$PIDF" ] && ok "客户端已运行" || no "客户端未运行"

echo "== 卸载并保留数据 =="
wizard_keep_data=true TRIM_APP_STATUS=UNINSTALL "$CMD/uninstall_init" >/dev/null 2>&1
[ "$(pgrep -f 'pkg/app/bin/fwclient' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && ok "客户端已停止" || no "客户端仍在运行"
[ "$(ps -ef | grep 'pkg/app/server/fwclient-server' | grep -v grep | wc -l)" = "0" ] && ok "管理后台已停止" || no "管理后台仍在运行"
[ -f "$TRIM_PKGVAR/run/fwclient.id" ] && ok "设备标识被保留" || no "保留分支：设备标识不应被删除"
TRIM_APP_STATUS=UNINSTALL "$CMD/uninstall_callback" >/dev/null 2>&1 && ok "uninstall_callback 退出 0" || no "uninstall_callback 失败"

echo "== 再启动一次，然后用删除分支卸载 =="
TRIM_APP_STATUS=START "$CMD/main" start
sleep 3
ID_BEFORE="$([ -f "$TRIM_PKGVAR/run/fwclient.id" ] && echo yes || echo no)"
echo "  卸载前设备标识存在：$ID_BEFORE"
wizard_keep_data=false TRIM_APP_STATUS=UNINSTALL "$CMD/uninstall_init" >/dev/null 2>&1
if [ "$ID_BEFORE" = "yes" ]; then
    [ -f "$TRIM_PKGVAR/run/fwclient.id" ] && no "删除分支：设备标识应被删除" || ok "删除分支：设备标识已删除"
fi
[ "$(pgrep -f 'pkg/app/bin/fwclient' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && ok "客户端已停止（删除分支）" || no "客户端仍在运行（删除分支）"

echo "== 清理 =="
pkill -f 'pkg/app/bin/fwclient' 2>/dev/null
pkill -f 'pkg/app/server/fwclient-server' 2>/dev/null
rm -rf "$WORK"
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
