#!/bin/bash
# 内网穿透（fwclient）· 公共函数库
# 被 cmd/ 下的生命周期脚本 source。

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
FWC_APPNAME="${TRIM_APPNAME:-fwclient}"
FWC_APPDEST="${TRIM_APPDEST:-/var/apps/${FWC_APPNAME}/target}"
FWC_ETC="${TRIM_PKGETC:-/var/apps/${FWC_APPNAME}/etc}"
FWC_VAR="${TRIM_PKGVAR:-/var/apps/${FWC_APPNAME}/var}"
FWC_TMP="${TRIM_PKGTMP:-/tmp}"

FWC_BINDIR="${FWC_APPDEST}/bin"
FWC_BIN="${FWC_BINDIR}/fwclient"
FWC_BINDIR_REL="bin"
FWC_SERVERDIR="${FWC_APPDEST}/server"
FWC_SERVER="${FWC_SERVERDIR}/fwclient-server"
FWC_RUNDIR="${FWC_VAR}/run"
FWC_CONFIG="${FWC_ETC}/config.json"
FWC_LOGFILE="${FWC_RUNDIR}/fwclient.log"
FWC_PIDFILE="${FWC_RUNDIR}/fwclient.pid"
FWC_IDFILE="${FWC_RUNDIR}/fwclient.id"
FWC_BACKEND_PID="${FWC_VAR}/backend.pid"
FWC_SCRIPT_LOG="${FWC_VAR}/lifecycle.log"
# 启动互斥锁：cmd/ 脚本与管理后台共用，见 fwc_lock_open
FWC_LOCKFILE="${FWC_VAR}/fwclient.lock"
# 手动停止标记：看护线程见到它就跳过自动重连（与管理后台的 StopFlag 同路径）
FWC_STOPFLAG="${FWC_VAR}/client.stopped"

# ---------------------------------------------------------------------------
# 日志：同时写应用日志文件和 fnOS 生命周期日志
# ---------------------------------------------------------------------------
fwc_log() {
    local stamp
    stamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # 生命周期日志：目录可能尚未创建或不可写（安装早期），不能因此报错
    if [ -w "${FWC_VAR}" ] || [ -w "${FWC_SCRIPT_LOG}" ]; then
        echo "${stamp} [${TRIM_APP_STATUS:-manual}] $*" >> "${FWC_SCRIPT_LOG}" 2>/dev/null || true
    fi

    # fnOS 用这个文件把信息展示给用户
    if [ -n "${TRIM_TEMP_LOGFILE:-}" ] && { [ -w "${TRIM_TEMP_LOGFILE}" ] || [ -w "$(dirname "${TRIM_TEMP_LOGFILE}")" ]; }; then
        echo "$*" >> "${TRIM_TEMP_LOGFILE}" 2>/dev/null || true
    fi
}

# fwc_fail 输出用户可见错误并以失败退出
# 同时写到生命周期日志、TRIM_TEMP_LOGFILE（应用中心弹窗）与 stderr（便于排查）
fwc_fail() {
    fwc_log "错误: $*"
    echo "错误: $*" >&2
    exit 1
}

# fwc_is_true 判断向导开关是否为「打开」。
# fnOS 向导开关在不同版本下可能给出 true/1/on/yes，这里统一收敛；
# 未识别的取值一律按「关闭」处理，避免出现意料之外的默认开启。
fwc_is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true | 1 | on | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# fwc_find_file <文件名> 在应用目录与安装临时目录中查找文件，输出其路径
fwc_find_file() {
    local name="$1"
    local d hit
    local roots=()

    if [ -f "${FWC_APPDEST}/${FWC_BINDIR_REL}/${name}" ]; then
        echo "${FWC_APPDEST}/${FWC_BINDIR_REL}/${name}"
        return 0
    fi

    [ -n "${TRIM_PKGTMP:-}" ] && roots+=("${TRIM_PKGTMP}")
    [ -n "${TRIM_PKGINST_TEMP_DIR:-}" ] && roots+=("${TRIM_PKGINST_TEMP_DIR}")
    [ -n "${TRIM_TEMP_TPKFILE:-}" ] && roots+=("${TRIM_TEMP_TPKFILE}")
    [ -n "${TRIM_APPDEST_VOL:-}" ] && roots+=("${TRIM_APPDEST_VOL}")
    roots+=("/var/apps/${FWC_APPNAME}" "${FWC_APPDEST}")

    for d in "${roots[@]}"; do
        [ -n "${d}" ] || continue
        [ -d "${d}" ] || continue
        hit="$(find "${d}" -maxdepth 6 -type f -name "${name}" 2>/dev/null | head -n 1)"
        if [ -n "${hit}" ]; then
            echo "${hit}"
            return 0
        fi
    done
    return 1
}

# fwc_note_writable <路径> <名称> 记录目录是否存在/可写（只记录，不判失败）
fwc_note_writable() {
    local path="$1"
    local label="$2"
    if [ -d "${path}" ]; then
        if [ -w "${path}" ]; then
            fwc_log "${label}: ${path}（存在，可写）"
        else
            fwc_log "${label}: ${path}（存在，当前用户不可写）"
        fi
    else
        fwc_log "${label}: ${path}（尚不存在）"
    fi
}

# fwc_ensure_dirs 准备运行所需目录；返回 1 表示关键目录不可写。
# 只在安装完成后与启动前调用，此时系统已创建并授权相关目录。
fwc_ensure_dirs() {
    mkdir -p "${FWC_BINDIR}" "${FWC_SERVERDIR}" "${FWC_RUNDIR}" "${FWC_ETC}" "${FWC_VAR}" "${FWC_TMP}" 2>/dev/null || true

    if [ ! -d "${FWC_VAR}" ]; then
        fwc_log "运行数据目录不存在且无法创建：${FWC_VAR}"
        return 1
    fi
    # 用临时文件实测可写性，比 -w 判断更可靠
    if ! ( : >"${FWC_VAR}/.write-test" ) 2>/dev/null; then
        fwc_log "运行数据目录不可写：${FWC_VAR}"
        return 1
    fi
    rm -f "${FWC_VAR}/.write-test" 2>/dev/null
    return 0
}

# fwc_note_layout 记录应用目录结构，便于排查安装/运行异常
fwc_note_layout() {
    fwc_log "应用目录: ${FWC_APPDEST} (可写=$([ -w "${FWC_APPDEST}" ] && echo yes || echo no))"
    if [ -d "${FWC_APPDEST}" ]; then
        local entry
        for entry in "${FWC_APPDEST}"/*; do
            [ -e "${entry}" ] || continue
            if [ -d "${entry}" ]; then
                fwc_log "  [目录] $(basename "${entry}")"
            else
                fwc_log "  [文件] $(basename "${entry}") $(wc -c <"${entry}" 2>/dev/null | tr -d ' ')B"
            fi
        done
    else
        fwc_log "  应用目录尚不存在"
    fi
}

# fwc_resolve_binaries 定位 fwclient 与后端程序，缺失时尝试从安装临时目录补齐。
# fnOS 在不同阶段提供的目录布局可能不同，这里做自适应而不是直接失败。
# 返回 0 表示两个程序都已就位。
fwc_resolve_binaries() {
    local src

    if [ ! -f "${FWC_BIN}" ]; then
        if src="$(fwc_find_file "$(basename "${FWC_BIN}")")"; then
            fwc_log "从 ${src} 补齐 $(basename "${FWC_BIN}")"
            mkdir -p "${FWC_BINDIR}" 2>/dev/null
            cp -f "${src}" "${FWC_BIN}" 2>/dev/null || fwc_log "复制失败: ${src}"
        fi
    fi

    if [ ! -f "${FWC_SERVER}" ]; then
        if src="$(fwc_find_file "$(basename "${FWC_SERVER}")")"; then
            fwc_log "从 ${src} 补齐 $(basename "${FWC_SERVER}")"
            mkdir -p "${FWC_SERVERDIR}" 2>/dev/null
            cp -f "${src}" "${FWC_SERVER}" 2>/dev/null || fwc_log "复制失败: ${src}"
        fi
    fi

    [ -f "${FWC_BIN}" ] && chmod 755 "${FWC_BIN}" 2>/dev/null
    [ -f "${FWC_SERVER}" ] && chmod 755 "${FWC_SERVER}" 2>/dev/null
    [ -f "${FWC_BIN}" ] && [ -f "${FWC_SERVER}" ]
}

# ---------------------------------------------------------------------------
# 用户与权限
# ---------------------------------------------------------------------------
# fwc_run_as 执行命令；root 生命周期脚本下自动降权到应用用户
fwc_run_as() {
    if [ "$(id -u)" = "0" ] && [ -n "${TRIM_USERNAME:-}" ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "${TRIM_USERNAME}" -- "$@"
    else
        "$@"
    fi
}

# fwc_chown_app 把应用目录交还给应用用户
fwc_chown_app() {
    if [ "$(id -u)" = "0" ] && [ -n "${TRIM_USERNAME:-}" ]; then
        chown -R "${TRIM_USERNAME}:${TRIM_GROUPNAME:-$TRIM_USERNAME}" "$@" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# 配置读写
# ---------------------------------------------------------------------------
# fwc_json_escape 简单转义，JSON 值与 shell 之间的转换
fwc_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# fwc_env_escape 转义写入 shell 单引号字符串的值
fwc_env_escape() {
    printf '%s' "$1" | sed -e "s/'/'\\\\''/g"
}

# fwc_write_config <网关> <令牌> [insecure] 生成 config.json
fwc_write_config() {
    local gateway="$1"
    local token="$2"
    local insecure="${3:-false}"

    mkdir -p "${FWC_ETC}" "${FWC_VAR}" "${FWC_RUNDIR}"

    # 保留已有的开关状态
    local autostart="true" autoreconn="true"
    if [ -f "${FWC_CONFIG}" ]; then
        grep -q '"autoStart"[[:space:]]*:[[:space:]]*false' "${FWC_CONFIG}" && autostart="false"
        grep -q '"autoReconn"[[:space:]]*:[[:space:]]*false' "${FWC_CONFIG}" && autoreconn="false"
    fi

    cat > "${FWC_CONFIG}.tmp" <<EOF
{
  "gateway": "$(fwc_json_escape "${gateway}")",
  "token": "$(fwc_json_escape "${token}")",
  "insecure": ${insecure},
  "autoStart": ${autostart},
  "autoReconn": ${autoreconn}
}
EOF
    mv "${FWC_CONFIG}.tmp" "${FWC_CONFIG}"
    chmod 600 "${FWC_CONFIG}" 2>/dev/null
    fwc_chown_app "${FWC_ETC}"

    # 同步一份 env 文件，便于脚本或用户直接调试 fwclient
    cat > "${FWC_ETC}/fwclient.env" <<EOF
FWCLIENT_SERVER='$(fwc_env_escape "${gateway}")'
FWCLIENT_TOKEN='$(fwc_env_escape "${token}")'
EOF
    chmod 600 "${FWC_ETC}/fwclient.env" 2>/dev/null
    fwc_chown_app "${FWC_ETC}"

    fwc_log "配置已写入 ${FWC_CONFIG}（网关=${gateway}）"
}

# fwc_load_config 从 config.json 读取配置到 FW_GATEWAY / FW_TOKEN / FW_INSECURE
# 同时读出自启与自动重连开关（缺省都视为打开）。
fwc_load_config() {
    FW_GATEWAY=""
    FW_TOKEN=""
    FW_INSECURE="false"
    FW_AUTOSTART="true"
    FW_AUTORECONN="true"
    [ -f "${FWC_CONFIG}" ] || return 0

    FW_GATEWAY="$(sed -n 's/.*"gateway"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${FWC_CONFIG}" | head -n 1)"
    FW_TOKEN="$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${FWC_CONFIG}" | head -n 1)"
    if grep -q '"insecure"[[:space:]]*:[[:space:]]*true' "${FWC_CONFIG}"; then
        FW_INSECURE="true"
    fi
    if grep -q '"autoStart"[[:space:]]*:[[:space:]]*false' "${FWC_CONFIG}"; then
        FW_AUTOSTART="false"
    fi
    if grep -q '"autoReconn"[[:space:]]*:[[:space:]]*false' "${FWC_CONFIG}"; then
        FW_AUTORECONN="false"
    fi
}

# fwc_apply_wizard 把向导变量写入配置（安装 / 配置变更流程使用）
# 令牌留空时保留原值。
fwc_apply_wizard() {
    local gateway="${wizard_gateway:-}"
    local token="${wizard_token:-}"
    local insecure="false"

    # 向导默认是「校验 TLS 证书 = 打开」，也就是 insecure=false。
    # 只有用户明确把「校验 TLS 证书」关掉时才跳过证书校验。
    # 兼容旧字段 wizard_insecure：它显式为真时才跳过校验。
    if [ -n "${wizard_verify_tls:-}" ]; then
        if ! fwc_is_true "${wizard_verify_tls}"; then
            insecure="true"
        fi
    elif fwc_is_true "${wizard_insecure:-}"; then
        insecure="true"
    fi

    if [ -z "${gateway}" ]; then
        # 没有向导值时保留已有配置
        if [ -f "${FWC_CONFIG}" ]; then
            fwc_log "向导未提供网关域名，保留原有配置"
            return 0
        fi
        fwc_fail "未提供网关域名，请在应用设置中填写后再启动"
    fi

    if [ -z "${token}" ] && [ -f "${FWC_CONFIG}" ]; then
        fwc_load_config
        token="${FW_TOKEN}"
        fwc_log "向导未提供新令牌，沿用已保存的令牌"
    fi

    if [ -z "${token}" ]; then
        fwc_fail "未提供访问令牌，请在应用设置中填写后再启动"
    fi

    fwc_write_config "${gateway}" "${token}" "${insecure}"
}

# ---------------------------------------------------------------------------
# 进程识别与启动互斥
# ---------------------------------------------------------------------------
# fwc_proc_cmdline <pid> 输出进程命令行（参数以空格分隔）；读不到时返回 1。
fwc_proc_cmdline() {
    local pid="$1" raw
    [ -n "${pid}" ] && [ -r "/proc/${pid}/cmdline" ] || return 1
    raw="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)" || return 1
    [ -n "${raw}" ] || return 1
    printf '%s' "${raw% }"
}

# fwc_is_client_cmdline <命令行> 判断是否为「本应用的 fwclient 守护进程」。
# 需要同时满足：程序是应用目录里的 fwclient、运行目录是本应用的 run 目录、
# 且不是 -k / -v / -u / -h 这类一次性命令（它们同样带 -dir，不能误杀）。
fwc_is_client_cmdline() {
    local cmd="$1"
    case "${cmd}" in
        "${FWC_BIN} "*) ;;
        *) return 1 ;;
    esac
    case "${cmd}" in
        *"-dir ${FWC_RUNDIR} "* | *"-dir ${FWC_RUNDIR}") ;;
        *) return 1 ;;
    esac
    case " ${cmd} " in
        *" -k "* | *" -v "* | *" -u "* | *" -h "*) return 1 ;;
    esac
    return 0
}

# fwc_client_pids 列出本应用全部 fwclient 守护进程 pid（每行一个）。
# 除 pid 文件里的那个之外，还可能存在历史遗留的重复进程，因此这里扫 /proc，
# 而不是只信 pid 文件。/proc 不可用时返回空，调用方退回 pid 文件判断。
fwc_client_pids() {
    local d pid cmd
    [ -d /proc ] || return 0
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        cmd="$(fwc_proc_cmdline "${pid}")" || continue
        if fwc_is_client_cmdline "${cmd}"; then
            echo "${pid}"
        fi
    done
    return 0
}

# fwc_lock_open 打开启动互斥锁。
#
# cmd/ 脚本与管理后台是两个互不相干的进程，却都要做「判断未运行 → 拉起客户端」。
# 只凭 pid 文件判断存在竞态窗口（客户端写完 pid 文件要几十毫秒），两边会各拉起
# 一个守护进程：pid 文件只记录后写入的那个，另一个就成了停止时也管不到的孤儿。
# 这里用 flock 把「判断 + 拉起」变成跨进程原子操作，锁文件由两边共用。
# 必须在子 shell 中调用：子 shell 退出时 fd 关闭，锁自动释放。
# 注意 flock 对只读打开的 fd 同样有效，因此锁文件属主是 root 时后端也能加锁。
fwc_lock_open() {
    command -v flock >/dev/null 2>&1 || return 0
    if [ -r "${FWC_LOCKFILE}" ]; then
        exec 9<"${FWC_LOCKFILE}" 2>/dev/null || return 0
    else
        exec 9>>"${FWC_LOCKFILE}" 2>/dev/null || return 0
    fi
    # 等锁最多 60 秒（对方最多等 pid 文件 10 秒）；超时也继续，保持可用性
    flock -w 60 9 2>/dev/null || fwc_log "启动锁等待超时，继续执行"
    return 0
}

# fwc_reap_stray_clients <保留 pid> 结束所有不属于 keep 的本应用客户端进程。
fwc_reap_stray_clients() {
    local keep="${1:-0}" pid alive
    [ -d /proc ] || return 0

    for pid in $(fwc_client_pids); do
        [ "${pid}" = "${keep}" ] && continue
        fwc_log "清理重复/残留的 fwclient 进程 pid=${pid}"
        kill -TERM "${pid}" 2>/dev/null || true
    done

    local i=0
    while [ $i -lt 15 ]; do
        alive=0
        for pid in $(fwc_client_pids); do
            [ "${pid}" = "${keep}" ] || alive=1
        done
        [ "${alive}" = "0" ] && return 0
        sleep 0.2
        i=$((i + 1))
    done

    for pid in $(fwc_client_pids); do
        [ "${pid}" = "${keep}" ] && continue
        fwc_log "强制结束 fwclient 进程 pid=${pid}"
        kill -KILL "${pid}" 2>/dev/null || true
    done
    return 0
}

# ---------------------------------------------------------------------------
# fwclient 进程控制
# ---------------------------------------------------------------------------
# fwc_client_pid 输出正在运行的 fwclient pid（0 表示未运行）
fwc_client_pid() {
    [ -r "${FWC_PIDFILE}" ] || { echo 0; return; }
    local pid
    pid="$(head -n 1 "${FWC_PIDFILE}" 2>/dev/null | tr -dc '0-9')"
    if [ -z "${pid}" ]; then
        echo 0
        return
    fi
    if kill -0 "${pid}" 2>/dev/null; then
        echo "${pid}"
    else
        rm -f "${FWC_PIDFILE}" 2>/dev/null
        echo 0
    fi
}

# fwc_running_pid 输出当前客户端 pid；0 表示未运行。
# pid 文件优先；客户端写完 pid 文件之前有几十毫秒窗口，这时用 /proc 扫描兜底，
# 否则「脚本 + 后端」两侧都会把「刚拉起」误判成「未运行」而各拉起一个进程。
fwc_running_pid() {
    local pid
    pid="$(fwc_client_pid)"
    if [ "${pid}" = "0" ]; then
        pid="$(fwc_client_pids | head -n 1)"
        [ -n "${pid}" ] || pid="0"
    fi
    echo "${pid}"
}

# fwc_start_client 启动 fwclient 守护进程（跨进程互斥，重复调用只会有一个客户端）
fwc_start_client() {
    fwc_load_config
    if [ -z "${FW_GATEWAY}" ] || [ -z "${FW_TOKEN}" ]; then
        fwc_log "尚未配置网关域名或令牌，跳过自动连接"
        return 0
    fi
    if ! fwc_is_true "${FW_AUTOSTART}"; then
        fwc_log "「开机自启」已关闭，跳过自动连接"
        return 0
    fi
    if [ ! -x "${FWC_BIN}" ]; then
        fwc_log "找不到可执行的 fwclient：${FWC_BIN}"
        return 1
    fi

    # 应用启动时按配置自动连接：这是用户/系统对这一轮运行的明确意图，
    # 因此清掉上一次的「手动停止」标记，让看护线程恢复正常看护
    rm -f "${FWC_STOPFLAG}" 2>/dev/null

    # 整个「判断 + 拉起」放在加锁的子 shell 中：退出即释放锁，不会与
    # 管理后台的自启动流程同时拉起两个客户端。
    (
        fwc_lock_open

        # 客户端写完 pid 文件有几十毫秒窗口，这段时间只看 pid 文件会误判为
        # 「未运行」；fwc_running_pid 会用 /proc 扫描兜底。
        local running_pid
        running_pid="$(fwc_running_pid)"

        if [ "${running_pid}" != "0" ]; then
            fwc_log "fwclient 已在运行 pid=${running_pid}，无需重复启动"
            # 历史遗留的重复进程顺手收敛掉，避免 pid 文件之外的进程越积越多
            fwc_reap_stray_clients "${running_pid}"
            exit 0
        fi
        fwc_reap_stray_clients 0

        local args=(-s "${FW_GATEWAY}" -t "${FW_TOKEN}" -dir "${FWC_RUNDIR}")
        [ "${FW_INSECURE}" = "true" ] && args+=(-insecure)

        fwc_log "启动 fwclient：-s ${FW_GATEWAY} -dir ${FWC_RUNDIR}"
        if [ "$(id -u)" = "0" ] && [ -n "${TRIM_USERNAME:-}" ]; then
            fwc_chown_app "${FWC_VAR}"
            ( cd "${FWC_BINDIR}" && fwc_run_as "${FWC_BIN}" "${args[@]}" -d ) >> "${FWC_VAR}/spawn.log" 2>&1
        else
            ( cd "${FWC_BINDIR}" && "${FWC_BIN}" "${args[@]}" -d ) >> "${FWC_VAR}/spawn.log" 2>&1
        fi

        # 等待 pid 文件出现
        local i=0
        while [ $i -lt 30 ]; do
            if [ "$(fwc_client_pid)" != "0" ]; then
                fwc_log "fwclient 已启动 pid=$(fwc_client_pid)"
                exit 0
            fi
            sleep 0.2
            i=$((i + 1))
        done
        fwc_log "fwclient 启动超时，请检查网关域名与令牌是否正确"
        exit 1
    )
}

# fwc_stop_client 规范关闭 fwclient，并清理全部重复/残留进程
fwc_stop_client() {
    (
        fwc_lock_open

        local pid
        pid="$(fwc_running_pid)"
        if [ "${pid}" != "0" ] && [ -x "${FWC_BIN}" ]; then
            # -k 会读写运行目录（pid / 日志），必须与客户端同用户执行，
            # 否则会在应用目录里留下 root 属主的文件
            if [ "$(id -u)" = "0" ] && [ -n "${TRIM_USERNAME:-}" ]; then
                ( cd "${FWC_BINDIR}" && fwc_run_as "${FWC_BIN}" -k -dir "${FWC_RUNDIR}" ) >/dev/null 2>&1
            else
                ( cd "${FWC_BINDIR}" && "${FWC_BIN}" -k -dir "${FWC_RUNDIR}" ) >/dev/null 2>&1
            fi

            local i=0
            while [ $i -lt 25 ]; do
                [ "$(fwc_running_pid)" = "0" ] && break
                sleep 0.2
                i=$((i + 1))
            done

            if [ "$(fwc_running_pid)" != "0" ]; then
                fwc_log "规范关闭超时，改为发送 TERM 信号 pid=${pid}"
                kill -TERM "${pid}" 2>/dev/null || true
                sleep 1
                if kill -0 "${pid}" 2>/dev/null; then
                    kill -KILL "${pid}" 2>/dev/null || true
                    sleep 1
                fi
            else
                fwc_log "fwclient 已规范关闭"
            fi
        fi

        rm -f "${FWC_PIDFILE}" 2>/dev/null
        # 兜底：pid 文件之外还活着的重复/残留进程一并清掉
        fwc_reap_stray_clients 0
        # 记下「用户主动停止」：管理后台的看护线程据此不再自动拉起客户端
        : > "${FWC_STOPFLAG}" 2>/dev/null || true
        fwc_chown_app "${FWC_VAR}" 2>/dev/null
        exit 0
    )
}

# ---------------------------------------------------------------------------
# 后端管理服务进程控制
# ---------------------------------------------------------------------------
fwc_backend_pid() {
    [ -r "${FWC_BACKEND_PID}" ] || { echo 0; return; }
    local pid cmd
    pid="$(head -n 1 "${FWC_BACKEND_PID}" 2>/dev/null | tr -dc '0-9')"
    if [ -z "${pid}" ]; then
        echo 0
        return
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
        echo 0
        return
    fi
    # pid 可能被系统复用：确认它确实是本应用的后端程序再认领
    if cmd="$(fwc_proc_cmdline "${pid}")"; then
        case "${cmd}" in
            *"${FWC_SERVER}" | *"${FWC_SERVER} "*) ;;
            *)
                fwc_log "pid 文件中的 ${pid} 不是本应用后端，忽略该 pid"
                echo 0
                return
                ;;
        esac
    fi
    echo "${pid}"
}

fwc_start_backend() {
    if [ ! -x "${FWC_SERVER}" ]; then
        fwc_log "找不到后端服务程序：${FWC_SERVER}"
        return 1
    fi

    # 已在运行就直接复用，避免重复拉起（第二个进程会因端口占用而退出，
    # 并把 pid 文件覆盖成已退出的 pid）
    local running
    running="$(fwc_backend_pid)"
    if [ "${running}" != "0" ]; then
        fwc_log "管理后台已在运行 pid=${running}，无需重复启动"
        return 0
    fi

    mkdir -p "${FWC_VAR}" "${FWC_TMP}" "${FWC_RUNDIR}"
    fwc_chown_app "${FWC_VAR}" "${FWC_TMP}"

    local port="${TRIM_SERVICE_PORT:-18443}"
    fwc_log "启动管理后台，端口 ${port}"

    cd "${FWC_APPDEST}" || return 1
    if [ "$(id -u)" = "0" ] && [ -n "${TRIM_USERNAME:-}" ]; then
        TRIM_SERVICE_PORT="${port}" FWCLIENT_RUN_USER="${TRIM_USERNAME}" \
            nohup runuser -u "${TRIM_USERNAME}" -- "${FWC_SERVER}" \
            >> "${FWC_VAR}/backend.out" 2>&1 &
    else
        TRIM_SERVICE_PORT="${port}" \
            nohup "${FWC_SERVER}" >> "${FWC_VAR}/backend.out" 2>&1 &
    fi
    echo $! > "${FWC_BACKEND_PID}"

    local i=0
    while [ $i -lt 25 ]; do
        if [ "$(fwc_backend_pid)" != "0" ] && kill -0 "$(fwc_backend_pid)" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    fwc_log "管理后台启动失败"
    return 1
}

fwc_stop_backend() {
    local pid
    pid="$(fwc_backend_pid)"
    if [ "${pid}" = "0" ]; then
        rm -f "${FWC_BACKEND_PID}" 2>/dev/null
        return 0
    fi
    kill -TERM "${pid}" 2>/dev/null
    local i=0
    while [ $i -lt 20 ]; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.2
        i=$((i + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}" 2>/dev/null
    fi
    rm -f "${FWC_BACKEND_PID}" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 二进制与目录准备
# ---------------------------------------------------------------------------
fwc_prepare_binaries() {
    mkdir -p "${FWC_BINDIR}" "${FWC_SERVERDIR}" "${FWC_RUNDIR}" "${FWC_ETC}" "${FWC_VAR}"

    # 设备标识：默认跟随二进制目录，统一收敛到运行目录
    if [ -f "${FWC_BINDIR}/fwclient.id" ] && [ ! -f "${FWC_IDFILE}" ]; then
        mv "${FWC_BINDIR}/fwclient.id" "${FWC_IDFILE}" 2>/dev/null
    fi

    # 启动互斥锁文件：脚本与后端共用，0644 让包用户也能只读打开（flock 对只读 fd 有效）
    if [ ! -e "${FWC_LOCKFILE}" ]; then
        : > "${FWC_LOCKFILE}" 2>/dev/null || true
        chmod 644 "${FWC_LOCKFILE}" 2>/dev/null || true
    fi

    fwc_resolve_binaries || true

    fwc_chown_app "${FWC_VAR}" "${FWC_ETC}"
    touch "${FWC_SCRIPT_LOG}" 2>/dev/null
}

# fwc_require_binaries 再次定位程序文件；缺失时输出用户可见错误并失败。
# 用于安装完成后与启动前，这两个阶段程序文件必须已经就位。
fwc_require_binaries() {
    if fwc_resolve_binaries; then
        return 0
    fi
    [ -f "${FWC_SERVER}" ] || fwc_log "缺少管理后台程序：${FWC_SERVER}"
    [ -f "${FWC_BIN}" ] || fwc_log "缺少客户端程序：${FWC_BIN}"
    fwc_note_layout
    fwc_fail "应用文件不完整，请重新安装应用包"
}

# fwc_check_token 校验令牌形态：tk_ 前缀 + 至少 4 位可见字符
fwc_check_token() {
    case "$1" in
        tk_????*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# fwc_check_gateway 校验网关域名形态
fwc_check_gateway() {
    case "$1" in
        *[!A-Za-z0-9._:-]*|"") return 1 ;;
        *) return 0 ;;
    esac
}
