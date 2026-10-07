#!/usr/bin/env bash
# 验证安装流程与 TLS 默认值的修复：
#   1) install_init 在 @appcenter 缺失、@appdata 不可写时不得阻断安装（真机两次报错都在这）
#   2) cmd/main start 在程序文件缺失时必须明确失败
#   3) TLS 证书校验默认开启，只有向导明确关闭时才写 insecure=true
set -uo pipefail

FPK="/mnt/d/软件开发/fnos/dist/fwclient-1.0.2.fpk"
WORK="$(mktemp -d /tmp/fwc-fix-XXXXXX)"
PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/pkg" "$WORK/pkg/app"
tar -xzf "$FPK" -C "$WORK/pkg"
tar -xzf "$WORK/pkg/app.tgz" -C "$WORK/pkg/app"
CMD="$WORK/pkg/cmd"
chmod +x "$CMD"/*

echo "== 1) 复现真机场景：@appcenter 尚不存在 + @appdata 不可写 =="
# 真机弹窗原文：
#   应用目录: /vol1/@appcenter/fwclient（尚不存在）
#   错误: 运行数据目录不可写: /vol1/@appdata/fwclient
EMPTY="$WORK/no-such-appcenter"
READONLY_VAR="$WORK/readonly-appdata"
mkdir -p "$READONLY_VAR"
chmod 500 "$READONLY_VAR"

export TRIM_APPNAME=fwclient TRIM_APPVER=1.0.1
export TRIM_APPDEST="$EMPTY"                     # 不存在的应用目录
export TRIM_PKGETC="$READONLY_VAR/etc"
export TRIM_PKGVAR="$READONLY_VAR"               # 不可写的数据目录
export TRIM_PKGTMP="$WORK/tmp"
export TRIM_TEMP_LOGFILE="$WORK/user.log"
export TRIM_USERNAME="$(id -un)" TRIM_GROUPNAME="$(id -gn)"
mkdir -p "$TRIM_PKGTMP"

OUT="$(TRIM_APP_STATUS=INSTALL "$CMD/install_init" 2>&1)"
RC=$?
if [ "$RC" = "0" ]; then
    ok "install_init 在目录缺失/不可写时仍返回 0（不再阻断安装）"
else
    no "install_init 返回 $RC：$OUT"
fi
if echo "$OUT" | grep -q '错误'; then
    no "install_init 仍输出错误信息：$OUT"
else
    ok "install_init 未输出任何错误信息"
fi
if echo "$OUT" | grep -q '错误\|Permission denied\|denied'; then
    no "install_init 输出异常信息：$OUT"
else
    ok "install_init 无错误输出（日志目录不可写时静默跳过写入）"
fi

echo "== 1b) 目录恢复可写后，install_callback 会准备运行目录 =="
chmod 700 "$READONLY_VAR"
export TRIM_APPDEST="$WORK/pkg/app"
OUT1B="$(TRIM_APP_STATUS=INSTALL "$CMD/install_callback" 2>&1)"
if [ -d "$TRIM_PKGVAR/run" ]; then
    ok "install_callback 已创建运行目录 var/run"
else
    no "未创建运行目录：$OUT1B"
fi

echo "== 2) cmd/main start 在程序文件缺失时必须明确报错，而不是静默失败 =="
export TRIM_APPDEST="$EMPTY"
OUT2="$(TRIM_APP_STATUS=START "$CMD/main" start 2>&1)"
RC2=$?
if [ "$RC2" != "0" ]; then
    ok "start 返回非 0（$RC2）"
else
    no "start 竟然返回 0"
fi
if echo "$OUT2" | grep -q '应用文件不完整'; then
    ok "给出了用户可见的错误提示"
else
    no "错误提示不清晰：$OUT2"
fi

echo "== 3) 应用文件就位后 install_init 正常（且不输出错误） =="
export TRIM_APPDEST="$WORK/pkg/app"
OUT3="$(TRIM_APP_STATUS=INSTALL "$CMD/install_init" 2>&1)"
RC3=$?
if [ "$RC3" -eq 0 ]; then
    ok "install_init 返回 0"
else
    no "install_init 返回 $RC3：$OUT3"
fi
if echo "$OUT3" | grep -q '错误\|Permission denied'; then
    no "install_init 输出异常信息：$OUT3"
else
    ok "install_init 无错误输出"
fi
LOG3="$TRIM_PKGVAR/lifecycle.log"
if grep -q '程序文件已就位\|应用目录' "$LOG3" 2>/dev/null; then
    ok "lifecycle.log 记录了检查结果"
else
    no "lifecycle.log 内容异常：$(tail -n 3 "$LOG3" 2>/dev/null)"
fi

echo "== 4) TLS 默认开启（向导开关为「校验 TLS 证书=1」） =="
rm -f "$TRIM_PKGETC/config.json"
wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 wizard_verify_tls=1 \
    TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
if grep -q '"insecure": false' "$TRIM_PKGETC/config.json"; then
    ok "默认写入 insecure=false（校验证书）"
else
    no "默认值不是 false：$(cat "$TRIM_PKGETC/config.json")"
fi

echo "== 5) 向导缺省该字段时也保持校验证书 =="
rm -f "$TRIM_PKGETC/config.json"
wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 \
    TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
if grep -q '"insecure": false' "$TRIM_PKGETC/config.json"; then
    ok "字段缺省时写入 insecure=false"
else
    no "字段缺省时未保持安全默认：$(cat "$TRIM_PKGETC/config.json")"
fi

echo "== 6) 用户明确关闭证书校验时才写入 insecure=true =="
rm -f "$TRIM_PKGETC/config.json"
wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 wizard_verify_tls=0 \
    TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
if grep -q '"insecure": true' "$TRIM_PKGETC/config.json"; then
    ok "关闭校验后写入 insecure=true"
else
    no "关闭校验未生效：$(cat "$TRIM_PKGETC/config.json")"
fi

echo "== 7) 旧字段 wizard_insecure 兼容（显式为真才跳过校验） =="
rm -f "$TRIM_PKGETC/config.json"
wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 wizard_insecure=false \
    TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
if grep -q '"insecure": false' "$TRIM_PKGETC/config.json"; then
    ok "wizard_insecure=false 不跳过校验"
else
    no "旧字段 false 被误判为跳过校验"
fi
rm -f "$TRIM_PKGETC/config.json"
wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 wizard_insecure=true \
    TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
if grep -q '"insecure": true' "$TRIM_PKGETC/config.json"; then
    ok "wizard_insecure=true 跳过校验"
else
    no "旧字段 true 未生效"
fi

echo "== 8) 「校验 TLS 证书」字段取值语义 =="
# 打开(=校验) 的取值，必须保持 insecure=false
for v in 1 true True TRUE on yes; do
    rm -f "$TRIM_PKGETC/config.json"
    wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 wizard_verify_tls="$v" \
        TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
    if grep -q '"insecure": false' "$TRIM_PKGETC/config.json" 2>/dev/null; then
        ok "verify_tls='$v' -> 校验证书"
    else
        no "verify_tls='$v' 未保持校验：$(cat "$TRIM_PKGETC/config.json" 2>/dev/null)"
    fi
done
# 关闭(=跳过校验) 的取值，应当 insecure=true
for v in 0 false no off; do
    rm -f "$TRIM_PKGETC/config.json"
    wizard_gateway=gw.example.com wizard_token=tk_defaulttest1234 wizard_verify_tls="$v" \
        TRIM_APP_STATUS=INSTALL "$CMD/install_callback" >/dev/null 2>&1
    if grep -q '"insecure": true' "$TRIM_PKGETC/config.json" 2>/dev/null; then
        ok "verify_tls='$v' -> 跳过证书校验"
    else
        no "verify_tls='$v' 未跳过校验：$(cat "$TRIM_PKGETC/config.json" 2>/dev/null)"
    fi
done

echo "== 9) 向导 JSON 中的开关默认值 =="
for f in install config; do
    if grep -q '"field": "wizard_verify_tls"' "$WORK/pkg/wizard/$f" &&
        grep -q '"initValue": "1"' "$WORK/pkg/wizard/$f"; then
        ok "wizard/$f 使用 wizard_verify_tls 且默认 \"1\""
    else
        no "wizard/$f 默认值不正确"
    fi
    if grep -q 'wizard_insecure' "$WORK/pkg/wizard/$f"; then
        no "wizard/$f 仍残留 wizard_insecure"
    else
        ok "wizard/$f 已移除 wizard_insecure"
    fi
done

pkill -f "$WORK/pkg/app/bin/fwclient" 2>/dev/null
pkill -f "$WORK/pkg/app/server/fwclient-server" 2>/dev/null
rm -rf "$WORK"
echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
