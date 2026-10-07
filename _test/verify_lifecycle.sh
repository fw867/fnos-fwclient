#!/usr/bin/env bash
# 在 WSL 下验证 cmd/ 生命周期脚本（模拟 fnOS 调用约定）。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPK="${FPK:-$(ls -1t "$REPO"/dist/*.fpk 2>/dev/null | head -n 1)}"
[ -f "$FPK" ] || { echo "找不到 .fpk，请先执行 ./build.sh"; exit 1; }
WORK="$(mktemp -d /tmp/fwc-life-XXXXXX)"
PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "== 解包 .fpk =="
mkdir -p "$WORK/pkg"
tar -xzf "$FPK" -C "$WORK/pkg"
mkdir -p "$WORK/pkg/app"
tar -xzf "$WORK/pkg/app.tgz" -C "$WORK/pkg/app"
ls -l "$WORK/pkg/cmd" | sed 's/^/  /'

# fnOS 布局
export TRIM_APPNAME=fwclient
export TRIM_APPVER=1.0.0
export TRIM_APPDEST="$WORK/pkg/app"
export TRIM_PKGETC="$WORK/etc"
export TRIM_PKGVAR="$WORK/var"
export TRIM_PKGTMP="$WORK/tmp"
export TRIM_SERVICE_PORT=18124
export TRIM_TEMP_LOGFILE="$WORK/user-visible.log"
export TRIM_USERNAME="$(id -un)"
export TRIM_GROUPNAME="$(id -gn)"
mkdir -p "$TRIM_PKGETC" "$TRIM_PKGVAR" "$TRIM_PKGTMP"

CMD="$WORK/pkg/cmd"
chmod +x "$CMD"/* 2>/dev/null

echo "== install_init（无向导变量，应成功） =="
TRIM_APP_STATUS=INSTALL "$CMD/install_init"
if [ $? -eq 0 ]; then ok "install_init 退出 0"; else no "install_init 失败"; cat "$WORK/user-visible.log" 2>/dev/null; fi

echo "== install_callback（带向导变量） =="
wizard_gateway=127.0.0.1 wizard_token=tk_lifecycle_test123 wizard_insecure=true \
    TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
if [ -f "$TRIM_PKGETC/config.json" ]; then ok "已写入 config.json"; cat "$TRIM_PKGETC/config.json" | sed 's/^/  /'; else no "未生成 config.json"; fi
[ -f "$TRIM_PKGETC/fwclient.env" ] && ok "已写入 fwclient.env" || no "未生成 fwclient.env"

echo "== main start =="
TRIM_APP_STATUS=START "$CMD/main" start
sleep 3
if TRIM_APP_STATUS=STATUS "$CMD/main" status; then ok "status 返回 0（运行中）"; else no "status 未返回 0"; fi
HTTP="$(curl -sS -m 8 http://127.0.0.1:18124/api/status)"
echo "  status => $(echo "$HTTP" | head -c 300)"
case "$HTTP" in
*'"running":true'*) ok "客户端已连接" ;;
*) no "客户端未连接" ;;
esac
case "$HTTP" in
*'"insecure":true'*) ok "向导的 insecure 生效" ;;
*) no "insecure 未生效" ;;
esac

echo "== config_callback（修改令牌，应通过管理后台重启客户端） =="
wizard_gateway=127.0.0.1 wizard_token=tk_lifecycle_test456 wizard_insecure=true \
    TRIM_APP_STATUS=CONFIG "$CMD/config_callback" >/dev/null 2>&1
sleep 4
HTTP2="$(curl -sS -m 8 http://127.0.0.1:18124/api/status)"
echo "  status => $(echo "$HTTP2" | head -c 260)"
case "$HTTP2" in
*'"tokenMasked":"tk_lif'*) ok "新令牌已生效" ;;
*) no "新令牌未生效" ;;
esac
case "$HTTP2" in
*'"running":true'*) ok "配置变更后客户端仍在运行" ;;
*) no "配置变更后客户端未运行" ;;
esac

echo "== config_init（非法令牌应失败） =="
if wizard_token=bad-token wizard_gateway=127.0.0.1 TRIM_APP_STATUS=CONFIG "$CMD/config_init" >/dev/null 2>&1; then
    no "非法令牌未被拒绝"
else
    ok "非法令牌被拒绝"
fi

echo "== main stop =="
TRIM_APP_STATUS=STOP "$CMD/main" stop
sleep 2
if TRIM_APP_STATUS=STATUS "$CMD/main" status; then no "stop 后仍在运行"; else ok "stop 后状态为未运行"; fi
pkill -f "fwclient-server" 2>/dev/null
pkill -f "app/bin/fwclient" 2>/dev/null

echo "== 生命周期日志 =="
tail -n 12 "$TRIM_PKGVAR/lifecycle.log" 2>/dev/null | sed 's/^/  /'

rm -rf "$WORK"
echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
