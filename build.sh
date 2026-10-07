#!/usr/bin/env bash
# 一键构建内网穿透（fwclient）fnOS 应用包。
#
# 用法：
#   ./build.sh                  # 构建 x86_64 应用包
#   ./build.sh --arm            # 额外构建 aarch64 后端（需自行替换 bin/fwclient）
#   ./build.sh --no-pack        # 只准备 app 目录，不执行 fnpack
#
# 依赖：go（1.22+）、fnpack（可用 FNPACK 环境变量指定路径）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${ROOT}/fwclient-app"
BACKEND="${APP}/backend"
DIST="${ROOT}/dist"

GO_BIN="${GO:-go}"
FNPACK_BIN="${FNPACK:-${ROOT}/_tools/fnpack.exe}"
PYTHON_BIN="${PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)}"
if ! command -v "${GO_BIN}" >/dev/null 2>&1; then
    if [ -x "/c/Program Files/Go/bin/go.exe" ]; then
        GO_BIN="/c/Program Files/Go/bin/go.exe"
    fi
fi

WITH_ARM=0
DO_PACK=1
for arg in "$@"; do
    case "${arg}" in
    --arm) WITH_ARM=1 ;;
    --no-pack) DO_PACK=0 ;;
    *) echo "未知参数：${arg}" >&2; exit 1 ;;
    esac
done

echo "==> 读取版本号"
VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "${APP}/manifest" | head -n 1 | tr -d '[:space:]')"
APPNAME="$(sed -n 's/^appname[[:space:]]*=[[:space:]]*//p' "${APP}/manifest" | head -n 1 | tr -d '[:space:]')"
echo "    ${APPNAME} ${VERSION}"

echo "==> 检查 fwclient 主程序"
if [ ! -f "${APP}/app/bin/fwclient" ]; then
    echo "    错误：缺少 ${APP}/app/bin/fwclient" >&2
    exit 1
fi

echo "==> 规范化脚本换行符（LF）与执行权限"
for f in "${APP}"/cmd/* "${APP}"/build.sh; do
    [ -f "${f}" ] || continue
    if command -v sed >/dev/null 2>&1; then
        # 去掉 CR，确保 Linux 下 shebang 可用
        sed -i 's/\r$//' "${f}" 2>/dev/null || true
    fi
done
chmod +x "${APP}"/cmd/* 2>/dev/null || true
chmod +x "${APP}"/build.sh 2>/dev/null || true

echo "==> 交叉编译后端（linux/amd64）"
mkdir -p "${APP}/app/server"
(
    cd "${BACKEND}"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        "${GO_BIN}" build -trimpath -ldflags "-s -w" -o "${APP}/app/server/fwclient-server" .
)

if [ "${WITH_ARM}" = "1" ]; then
    echo "==> 交叉编译后端（linux/arm64）"
    (
        cd "${BACKEND}"
        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
            "${GO_BIN}" build -trimpath -ldflags "-s -w" -o "${APP}/app/server/fwclient-server-arm64" .
    )
    echo "    注意：需自行获取 aarch64 版 fwclient 并放到 app/bin/，否则 arm64 设备不可用"
fi

echo "==> 校验包结构"
for f in manifest ICON.PNG ICON_256.PNG config/privilege config/resource app/ui/config; do
    [ -f "${APP}/${f}" ] || { echo "    错误：缺少 ${f}" >&2; exit 1; }
done
for d in app cmd wizard; do
    [ -d "${APP}/${d}" ] || { echo "    错误：缺少目录 ${d}" >&2; exit 1; }
done

if [ "${DO_PACK}" = "1" ]; then
    echo "==> 打包 .fpk"
    mkdir -p "${DIST}"
    OUT_FPK="${DIST}/${APPNAME}-${VERSION}.fpk"
    if [ -x "${FNPACK_BIN}" ] || command -v "${FNPACK_BIN}" >/dev/null 2>&1; then
        rm -f "${ROOT}/${APPNAME}.fpk"
        "${FNPACK_BIN}" build --directory "${APP}"
        mv -f "${ROOT}/${APPNAME}.fpk" "${OUT_FPK}"
        if [ -n "${PYTHON_BIN}" ] && [ -f "${ROOT}/repack_fpk.py" ]; then
            "${PYTHON_BIN}" "${ROOT}/repack_fpk.py" "${OUT_FPK}"
        fi
        echo "    产物：${OUT_FPK}"
    elif [ -n "${PYTHON_BIN}" ] && [ -f "${ROOT}/pack_fpk.py" ]; then
        echo "    未找到 fnpack，改用 pack_fpk.py 直接打包（布局与 fnpack 产物一致）"
        "${PYTHON_BIN}" "${ROOT}/pack_fpk.py" "${APP}" "${OUT_FPK}"
        echo "    产物：${OUT_FPK}"
    else
        echo "    未找到 fnpack 与 python，跳过打包（可用 FNPACK=/path/to/fnpack 指定）"
    fi
fi

echo "==> 完成"
