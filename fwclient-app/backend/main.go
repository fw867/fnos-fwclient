// fwclient-app backend
//
// 内网穿透（fwclient）飞牛 fnOS 应用的后端服务：
//   - 托管管理页面（静态资源内嵌，无外部依赖）
//   - 读写网关域名 / 令牌配置
//   - 拉起、监控、规范关闭 fwclient 守护进程
//   - 读取 fwclient 日志、查询版本、检查升级
//
// 仅使用 Go 标准库，交叉编译为 linux/amd64 静态二进制。
package main

import (
	"bufio"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	appName    = "fwclient"
	appDisplay = "内网穿透"
	// appVersion 是管理后端自身的版本，需与 fwclient-app/manifest 的 version 保持一致
	appVersion = "1.0.3"
)

// ---------------------------------------------------------------------------
// 环境与路径
// ---------------------------------------------------------------------------

// env 读取环境变量，为空时返回默认值。
func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

// Paths 保存应用运行期需要的全部路径。
type Paths struct {
	AppDest  string // 程序目录（TRIM_APPDEST）
	PkgEtc   string // 配置目录（TRIM_PKGETC）
	PkgVar   string // 运行数据目录（TRIM_PKGVAR）
	PkgTmp   string // 临时目录（TRIM_PKGTMP）
	RunDir   string // fwclient 运行数据目录（pid/日志/设备标识）
	LogFile  string // fwclient 日志
	PidFile  string // fwclient pid
	IDFile   string // fwclient 设备标识
	Config   string // 应用配置 json
	Binary   string // fwclient 二进制
	LockFile string // 启动互斥锁（与 cmd/lib.sh 共用）
	StopFlag string // 用户手动停止的标记（看护线程据此不再自动重连）
	RunUser  string // 以哪个用户运行 fwclient（root 生命周期脚本降权用）
	HomePage string
}

// resolvePaths 计算所有路径。所有路径都可以通过环境变量覆盖，
// 这样既适配 fnOS 的 TRIM_* 变量，也方便在开发机上做功能自测。
func resolvePaths() Paths {
	appDest := env("TRIM_APPDEST", env("FWCLIENT_APPDEST", "."))
	pkgEtc := env("TRIM_PKGETC", env("FWCLIENT_PKGETC", filepath.Join(appDest, "etc")))
	pkgVar := env("TRIM_PKGVAR", env("FWCLIENT_PKGVAR", filepath.Join(appDest, "var")))
	pkgTmp := env("TRIM_PKGTMP", env("FWCLIENT_PKGTMP", os.TempDir()))

	runDir := env("FWCLIENT_RUNDIR", filepath.Join(pkgVar, "run"))

	p := Paths{
		AppDest:  appDest,
		PkgEtc:   pkgEtc,
		PkgVar:   pkgVar,
		PkgTmp:   pkgTmp,
		RunDir:   runDir,
		LogFile:  env("FWCLIENT_LOGFILE", filepath.Join(runDir, "fwclient.log")),
		PidFile:  env("FWCLIENT_PIDFILE", filepath.Join(runDir, "fwclient.pid")),
		IDFile:   env("FWCLIENT_IDFILE", filepath.Join(runDir, "fwclient.id")),
		Config:   env("FWCLIENT_CONFIG", filepath.Join(pkgEtc, "config.json")),
		Binary:   env("FWCLIENT_BIN", ""),
		LockFile: env("FWCLIENT_LOCKFILE", filepath.Join(pkgVar, "fwclient.lock")),
		StopFlag: env("FWCLIENT_STOPFLAG", filepath.Join(pkgVar, "client.stopped")),
		RunUser:  strings.TrimSpace(os.Getenv("FWCLIENT_RUN_USER")),
	}
	if p.Binary == "" {
		name := "fwclient"
		if runtime.GOOS == "windows" {
			name = "fwclient.exe"
		}
		p.Binary = filepath.Join(appDest, "bin", name)
	}
	return p
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

// Config 是持久化到 config.json 的应用配置。
type Config struct {
	Gateway    string `json:"gateway"`    // 网关域名或 IP，例如 fw867.com
	Token      string `json:"token"`      // 访问令牌，例如 tk_xxxx
	Insecure   bool   `json:"insecure"`   // 跳过 TLS 证书校验（自签证书场景）
	AutoStart  bool   `json:"autoStart"`  // 应用启动时自动连接
	AutoReconn bool   `json:"autoReconn"` // 进程意外退出后自动重连
}

func defaultConfig() Config {
	return Config{AutoStart: true, AutoReconn: true}
}

// 网关域名/IP 白名单校验：只允许字母、数字、点、连字符、下划线和冒号。
var gatewayRe = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._:\-]{0,252}[A-Za-z0-9])?$`)

// tokenRe 与 fwclient 的令牌形态保持一致：tk_ 前缀 + 可见字符。
var tokenRe = regexp.MustCompile(`^tk_[A-Za-z0-9_.\-]{4,200}$`)

func validateGateway(v string) error {
	if v == "" {
		return errors.New("网关域名不能为空")
	}
	if !gatewayRe.MatchString(v) {
		return errors.New("网关域名格式不合法，只能包含字母、数字、点、连字符、下划线和冒号")
	}
	return nil
}

func validateToken(v string) error {
	if v == "" {
		return errors.New("访问令牌不能为空")
	}
	if !tokenRe.MatchString(v) {
		return errors.New("令牌格式不合法，应为 tk_ 开头的字母数字串")
	}
	return nil
}

// ---------------------------------------------------------------------------
// 应用主体
// ---------------------------------------------------------------------------

type App struct {
	paths Paths
	mu    sync.Mutex

	// opsMu 串行化进程操作（启动/停止/重启），避免接口与看护线程互相打断
	opsMu sync.Mutex

	// 升级任务的输出缓冲
	upgradeRunning bool
	upgradeLog     []string

	// 版本缓存，避免每次刷新都执行子进程
	verMu     sync.Mutex
	verCache  string
	verAt     time.Time
	lastError string

	// tracked 记录本进程最近一次拉起的 fwclient pid。
	// 真实客户端在部分场景下会让 pid 文件短暂消失，仅依赖 pid 文件会误判为「未运行」。
	trackMu   sync.Mutex
	trackedID int
}

func NewApp(p Paths) *App {
	return &App{paths: p}
}

// --- 配置文件读写 -----------------------------------------------------------

func (a *App) loadConfig() Config {
	cfg := defaultConfig()
	raw, err := os.ReadFile(a.paths.Config)
	if err != nil {
		return cfg
	}
	_ = json.Unmarshal(raw, &cfg)
	return cfg
}

func (a *App) saveConfig(cfg Config) error {
	if err := os.MkdirAll(filepath.Dir(a.paths.Config), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	tmp := a.paths.Config + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.paths.Config)
}

// ensureLayout 创建运行期需要的目录。
func (a *App) ensureLayout() {
	for _, d := range []string{a.paths.PkgEtc, a.paths.PkgVar, a.paths.PkgTmp, a.paths.RunDir} {
		if d == "" {
			continue
		}
		_ = os.MkdirAll(d, 0o755)
	}
}

// --- fwclient 进程管理 ------------------------------------------------------

// pid 读取 pid 文件；返回 0 表示没有有效 pid。
func (a *App) pid() int {
	raw, err := os.ReadFile(a.paths.PidFile)
	if err != nil {
		return 0
	}
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return 0
	}
	// 兼容 "1234" 与 "1234\n" 之外可能出现的多余内容
	if f := strings.Fields(s); len(f) > 0 {
		s = f[0]
	}
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

// processAlive 判断 pid 是否存活。
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	if runtime.GOOS == "windows" {
		out, err := exec.Command("tasklist", "/FI", fmt.Sprintf("PID eq %d", pid), "/NH").Output()
		if err != nil {
			return false
		}
		return strings.Contains(string(out), strconv.Itoa(pid))
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return proc.Signal(syscallSignalZero) == nil
}

// daemonRunning 返回 (pid, 是否运行中)。
func (a *App) daemonRunning() (int, bool) {
	pid := a.pid()
	if pid == 0 {
		// pid 文件缺失时回退到本进程跟踪的 pid，避免误判为未运行
		if tracked := a.trackedPid(); tracked != 0 && processAlive(tracked) {
			return tracked, true
		}
		return 0, false
	}
	if processAlive(pid) {
		return pid, true
	}
	// pid 文件残留，清理掉
	_ = os.Remove(a.paths.PidFile)
	if tracked := a.trackedPid(); tracked != 0 && tracked != pid && processAlive(tracked) {
		return tracked, true
	}
	return 0, false
}

func (a *App) trackedPid() int {
	a.trackMu.Lock()
	defer a.trackMu.Unlock()
	return a.trackedID
}

func (a *App) setTrackedPid(pid int) {
	a.trackMu.Lock()
	a.trackedID = pid
	a.trackMu.Unlock()
}

// runningPid 返回当前客户端的 pid；0 表示没有运行。
//
// 先信 pid 文件（并保留 tracked pid 兜底），再用 /proc 扫一遍：
// 客户端从拉起（-d）到写出 pid 文件有几十毫秒的窗口，这段时间只看 pid 文件
// 会把「已经拉起」误判成「未运行」，从而重复拉起第二个守护进程。
func (a *App) runningPid() int {
	if pid, ok := a.daemonRunning(); ok {
		return pid
	}
	if pids := a.daemonPids(); len(pids) > 0 {
		return pids[0]
	}
	return 0
}

// --- 手动停止标记 -----------------------------------------------------------
// 用户点了「规范关闭」之后，客户端不应该被看护线程在 30 秒后又拉起来。
// 这里用一个标记文件记录「用户主动停止」，看护线程读到它就跳过自动重连；
// 任何一次成功启动（页面启动/重启/保存配置/应用启动）都会清掉它。
// 标记文件与 cmd/lib.sh 的 FWC_STOPFLAG 指向同一个路径。

func (a *App) markStopped() {
	if a.paths.StopFlag == "" {
		return
	}
	_ = os.WriteFile(a.paths.StopFlag, []byte(time.Now().Format(time.RFC3339)+"\n"), 0o644)
}

func (a *App) clearStopped() {
	if a.paths.StopFlag == "" {
		return
	}
	_ = os.Remove(a.paths.StopFlag)
}

func (a *App) stoppedByUser() bool {
	if a.paths.StopFlag == "" {
		return false
	}
	_, err := os.Stat(a.paths.StopFlag)
	return err == nil
}

// fwclientArgs 组装启动参数。
func (a *App) fwclientArgs(cfg Config) []string {
	args := []string{
		"-s", cfg.Gateway,
		"-t", cfg.Token,
		"-dir", a.paths.RunDir,
	}
	// insecure 必须显式传给客户端，否则「校验 TLS 证书」开关对自启动/页面启动无效
	// （只有 cmd/main start 的脚本路径会带，两边行为必须一致）
	if cfg.Insecure {
		args = append(args, "-insecure")
	}
	return args
}

// lockStart 获取跨进程启动互斥锁，与 cmd/lib.sh 的 flock 使用同一个锁文件。
// 脚本与管理后端都要做「判断未运行 → 拉起客户端」，没有这把锁就会各拉起一个
// 守护进程（pid 文件只记录后写入的那个，另一个成为无法停止的孤儿）。
// 加锁失败不阻断启动：只记录日志并返回空锁，退回原行为。
func (a *App) lockStart() *startLock {
	lk, err := acquireStartLock(a.paths.LockFile, 60*time.Second)
	if err != nil {
		log.Printf("[启动锁] 加锁失败（继续执行）：%v", err)
		return nil
	}
	return lk
}

// spawn 以守护进程方式拉起 fwclient（调用方需确保互斥）。
func (a *App) spawn() error {
	a.opsMu.Lock()
	defer a.opsMu.Unlock()
	return a.spawnLocked()
}

// startSerialized 串行化的「未运行则启动」。
// 先锁进程内的 opsMu，再锁进程间的锁文件，最后二次确认客户端确实没在运行。
func (a *App) startSerialized() error {
	a.opsMu.Lock()
	defer a.opsMu.Unlock()

	if pid := a.runningPid(); pid != 0 {
		// 已经在运行：顺手收敛 pid 文件之外的重复进程
		a.reapStrayDaemons(pid)
		return nil
	}

	lk := a.lockStart()
	defer lk.release()

	// 拿到锁后重新判断：cmd/ 脚本可能刚刚把客户端拉起
	if pid := a.runningPid(); pid != 0 {
		a.reapStrayDaemons(pid)
		return nil
	}
	a.reapStrayDaemons(0)
	return a.spawnLocked()
}

func (a *App) spawnLocked() error {
	cfg := a.loadConfig()
	if err := validateGateway(cfg.Gateway); err != nil {
		return err
	}
	if err := validateToken(cfg.Token); err != nil {
		return err
	}
	if _, err := os.Stat(a.paths.Binary); err != nil {
		return fmt.Errorf("找不到 fwclient 程序：%s", a.paths.Binary)
	}

	// 注意：这里不能删除 pid 文件。删除会与「停止」流程竞争：
	// 停止流程先读到 pid，随后 fwclient -k 因为文件已消失而无法通知守护进程退出。
	// 残留的 pid 文件由 daemonRunning() 在判定进程不存在时清理。

	args := append(a.fwclientArgs(cfg), "-d")
	cmd := exec.Command(a.paths.Binary, args...)
	cmd.Dir = filepath.Dir(a.paths.Binary)
	// 子进程输出重定向到文件，避免污染父进程 stdout
	logf, err := os.OpenFile(filepath.Join(a.paths.PkgVar, "spawn.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err == nil {
		defer logf.Close()
		cmd.Stdout = logf
		cmd.Stderr = logf
	}
	a.setRunUser(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动 fwclient 失败：%w", err)
	}
	// fwclient -d 会自己 daemonize，父进程很快退出
	_ = cmd.Wait()

	// 等待 pid 文件出现，最多 10 秒
	for i := 0; i < 50; i++ {
		if pid := a.runningPid(); pid != 0 {
			a.setTrackedPid(pid)
			a.clearError()
			// 已经跑起来了：清掉「用户主动停止」标记，看护线程恢复自动重连
			a.clearStopped()
			log.Printf("[启动] fwclient 已运行 pid=%d", pid)
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("fwclient 启动超时，请查看日志确认网关域名与令牌是否正确")
}

// stop 规范关闭 fwclient；返回是否已停止。
func (a *App) stop() error {
	a.opsMu.Lock()
	defer a.opsMu.Unlock()
	return a.stopLocked()
}

// errUngracefulStop 表示进程已结束，但没能走 fwclient 的规范关闭流程。
var errUngracefulStop = errors.New("ungraceful stop")

// stopLocked 关闭客户端，标记「用户主动停止」，并回收 pid 文件之外的重复/残留进程。
func (a *App) stopLocked() error {
	err := a.stopDaemonLocked()
	// 历史遗留的重复进程（pid 文件里没有记录的那些）在这里一并清掉，
	// 否则它们既不会被停止，也不会被状态接口看到——「点了停止却还在跑」
	// 通常就是它们（旧版本的重复实例）。
	a.reapStrayDaemons(0)
	// 记下这是用户的主动停止：看护线程不得在 30 秒后自动拉起
	a.markStopped()
	return err
}

func (a *App) stopDaemonLocked() error {
	pid := a.pid()
	pidFileRaw := ""
	if raw, err := os.ReadFile(a.paths.PidFile); err == nil {
		pidFileRaw = strings.TrimSpace(string(raw))
	} else {
		pidFileRaw = "<" + err.Error() + ">"
	}
	if pid == 0 {
		// pid 文件缺失：回退到本进程跟踪的 pid，再退回 /proc 扫描结果
		pid = a.trackedPid()
	}
	if pid == 0 {
		pid = a.runningPid()
	}
	if pid == 0 || !processAlive(pid) {
		log.Printf("[停止] 没有正在运行的 fwclient (pidFile=%q tracked=%d)", pidFileRaw, a.trackedPid())
		_ = os.Remove(a.paths.PidFile)
		a.setTrackedPid(0)
		return nil
	}
	log.Printf("[停止] 目标 pid=%d (pidFile=%q)", pid, pidFileRaw)

	// 优先用官方规范关闭方式：通知服务端断开后再退出。
	// 必须带上 -dir，否则 fwclient 会去默认路径找 pid 文件而找不到目标进程。
	// 客户端在退出过程中会自行清理 pid 文件，因此只以「进程是否还活着」为判据。
	graceful := false
	for attempt := 1; attempt <= 3; attempt++ {
		out, err := a.runForeground("-k", "-dir", a.paths.RunDir)
		if err != nil {
			log.Printf("[停止] fwclient -k 第 %d 次返回：%v (%s)", attempt, err, out)
		} else if out != "" {
			log.Printf("[停止] fwclient -k 第 %d 次：%s", attempt, out)
		}
		for i := 0; i < 8; i++ {
			if !processAlive(pid) {
				graceful = true
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		if graceful {
			break
		}
	}
	if graceful {
		a.cleanupAfterStop()
		log.Printf("[停止] fwclient pid=%d 已规范关闭", pid)
		return nil
	}

	// 兜底：直接结束进程。注意：fwclient 的 pid 文件在部分场景下会被它自己删除，
	// 因此这里只以「进程是否存活」为准，不能因为 pid 文件消失就判定已停止。
	log.Printf("[停止] 规范关闭超时，发送 TERM 给 pid=%d", pid)
	if p, err := os.FindProcess(pid); err == nil {
		_ = p.Signal(terminateSignal)
	}
	for i := 0; i < 15; i++ {
		if !processAlive(pid) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if processAlive(pid) {
		log.Printf("[停止] TERM 未生效，强制结束 pid=%d", pid)
		if p, err := os.FindProcess(pid); err == nil {
			_ = p.Kill()
		}
		for i := 0; i < 10; i++ {
			if !processAlive(pid) {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
	if processAlive(pid) {
		return fmt.Errorf("无法停止 fwclient (pid=%d)", pid)
	}
	a.cleanupAfterStop()
	return fmt.Errorf("%w: fwclient pid=%d 未响应规范关闭，已改用信号结束进程", errUngracefulStop, pid)
}

// cleanupAfterStop 清理停止后的残留状态。
func (a *App) cleanupAfterStop() {
	_ = os.Remove(a.paths.PidFile)
	a.setTrackedPid(0)
}

// daemonPids 返回当前所有属于本应用的 fwclient 守护进程 pid
// （含 pid 文件里记录的那个，以及历史遗留的重复进程）。
func (a *App) daemonPids() []int {
	return daemonPids(a.paths.Binary, a.paths.RunDir)
}

// reapStrayDaemons 结束除 keep 之外的本应用客户端进程。
// keep 传 0 表示全部结束。用于停止流程、以及启动时自愈历史重复进程。
func (a *App) reapStrayDaemons(keep int) {
	strays := func() []int {
		var left []int
		for _, pid := range a.daemonPids() {
			if pid != keep {
				left = append(left, pid)
			}
		}
		return left
	}

	left := strays()
	if len(left) == 0 {
		return
	}
	for _, pid := range left {
		log.Printf("[清理] 结束重复/残留的 fwclient 进程 pid=%d（保留 %d）", pid, keep)
		if p, err := os.FindProcess(pid); err == nil {
			_ = p.Signal(terminateSignal)
		}
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if len(strays()) == 0 {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	for _, pid := range strays() {
		log.Printf("[清理] 强制结束 fwclient 进程 pid=%d", pid)
		if p, err := os.FindProcess(pid); err == nil {
			_ = p.Kill()
		}
	}
}

// restart 先关闭再拉起。
func (a *App) restart() error {
	a.opsMu.Lock()
	defer a.opsMu.Unlock()

	lk := a.lockStart()
	defer lk.release()

	// 非规范关闭不算失败：进程已经结束，可以继续拉起
	if err := a.stopLocked(); err != nil && !errors.Is(err, errUngracefulStop) {
		return err
	}
	time.Sleep(400 * time.Millisecond)
	return a.spawnLocked()
}

// runForeground 同步执行 fwclient 参数（用于 -k / -u / -v 这类一次性命令），
// 返回合并后的输出。
func (a *App) runForeground(args ...string) (string, error) {
	if _, err := os.Stat(a.paths.Binary); err != nil {
		return "", fmt.Errorf("找不到 fwclient 程序：%s", a.paths.Binary)
	}
	cmd := exec.Command(a.paths.Binary, args...)
	cmd.Dir = filepath.Dir(a.paths.Binary)
	a.setRunUser(cmd)
	out, err := cmd.CombinedOutput()
	// 便于排查：记录完整命令与结果
	log.Printf("[命令] %s %v (cwd=%s) => %q err=%v", a.paths.Binary, args, cmd.Dir, decodeOutput(out), err)
	return decodeOutput(out), err
}

// runUser 与降权 -------------------------------------------------------------

// setRunUser 在 root 生命周期脚本下把子进程降权到应用用户。
// 非 root 或没有配置用户时不做任何处理。
func (a *App) setRunUser(cmd *exec.Cmd) {
	if a.paths.RunUser == "" || runtime.GOOS == "windows" {
		return
	}
	if os.Geteuid() != 0 {
		return
	}
	uid, gid, err := lookupUser(a.paths.RunUser)
	if err != nil {
		log.Printf("[警告] 无法解析用户 %s：%v", a.paths.RunUser, err)
		return
	}
	cmd.SysProcAttr = sysProcAttrForUser(uid, gid)
}

// --- 版本与升级 -------------------------------------------------------------

// version 执行 fwclient -v；结果缓存 5 分钟。
func (a *App) version(force bool) string {
	a.verMu.Lock()
	defer a.verMu.Unlock()
	if !force && a.verCache != "" && time.Since(a.verAt) < 5*time.Minute {
		return a.verCache
	}
	out, err := a.runForeground("-v")
	out = strings.TrimSpace(out)
	if err != nil && out == "" {
		return "未知"
	}
	a.verCache = firstLine(out)
	a.verAt = time.Now()
	return a.verCache
}

func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}

// startUpgrade 异步执行 fwclient -u，输出写入 upgradeLog 供前端轮询。
func (a *App) startUpgrade() error {
	a.mu.Lock()
	if a.upgradeRunning {
		a.mu.Unlock()
		return errors.New("已有升级任务在进行中")
	}
	a.upgradeRunning = true
	a.upgradeLog = []string{fmt.Sprintf("[%s] 开始检查更新…", time.Now().Format("15:04:05"))}
	a.mu.Unlock()

	go func() {
		defer func() {
			a.mu.Lock()
			a.upgradeRunning = false
			a.mu.Unlock()
			a.version(true) // 升级后刷新版本缓存
		}()

		if _, err := os.Stat(a.paths.Binary); err != nil {
			a.appendUpgrade("找不到 fwclient 程序，无法升级")
			return
		}
		cmd := exec.Command(a.paths.Binary, "-u")
		cmd.Dir = filepath.Dir(a.paths.Binary)
		a.setRunUser(cmd)
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			a.appendUpgrade("无法读取升级输出：" + err.Error())
			return
		}
		cmd.Stderr = cmd.Stdout
		if err := cmd.Start(); err != nil {
			a.appendUpgrade("升级进程启动失败：" + err.Error())
			return
		}
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			a.appendUpgrade(decodeOutput(sc.Bytes()))
		}
		if err := cmd.Wait(); err != nil {
			a.appendUpgrade("升级进程退出：" + err.Error())
		} else {
			a.appendUpgrade("升级流程结束")
		}
	}()
	return nil
}

func (a *App) appendUpgrade(line string) {
	line = strings.TrimRight(line, "\r\n")
	if strings.TrimSpace(line) == "" {
		return
	}
	a.mu.Lock()
	a.upgradeLog = append(a.upgradeLog, line)
	if len(a.upgradeLog) > 400 {
		a.upgradeLog = a.upgradeLog[len(a.upgradeLog)-400:]
	}
	a.mu.Unlock()
}

func (a *App) setUpgradeError(msg string) {
	a.mu.Lock()
	a.lastError = msg
	a.mu.Unlock()
}

func (a *App) clearError() {
	a.mu.Lock()
	a.lastError = ""
	a.mu.Unlock()
}

// --- 日志读取 ---------------------------------------------------------------

// tailLog 读取日志文件末尾的 max 行。
func (a *App) tailLog(max int) ([]string, int64, error) {
	f, err := os.Open(a.paths.LogFile)
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, 0, nil
		}
		return nil, 0, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, 0, err
	}
	size := st.Size()

	// 从文件尾部按块回读，避免大日志全量载入
	const chunk = 64 * 1024
	buf := make([]byte, 0, chunk)
	pos := size
	lines := 0
	for pos > 0 && lines <= max {
		readSize := int64(chunk)
		if pos < readSize {
			readSize = pos
		}
		pos -= readSize
		block := make([]byte, readSize)
		if _, err := f.ReadAt(block, pos); err != nil && err != io.EOF {
			return nil, size, err
		}
		buf = append(block, buf...)
		lines = strings.Count(string(buf), "\n")
	}
	text := string(buf)
	if strings.TrimSpace(text) == "" {
		return []string{}, size, nil
	}
	all := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if len(all) > max {
		all = all[len(all)-max:]
	}
	// 第一行可能是被截断的半行，去掉
	if pos > 0 && len(all) > 1 {
		all = all[1:]
	}
	return all, size, nil
}

// --- 守护进程看护 -----------------------------------------------------------

// watchdog 在 AutoReconn 打开时监控 fwclient，意外退出则自动重连。
func (a *App) watchdog() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	missed := 0
	for range ticker.C {
		cfg := a.loadConfig()
		if !cfg.AutoReconn || !cfg.AutoStart {
			missed = 0
			continue
		}
		if err := validateGateway(cfg.Gateway); err != nil {
			missed = 0
			continue
		}
		if err := validateToken(cfg.Token); err != nil {
			missed = 0
			continue
		}
		// 有升级任务时不干预，避免与二进制替换冲突
		a.mu.Lock()
		busy := a.upgradeRunning
		a.mu.Unlock()
		if busy {
			continue
		}
		// 用户刚点过「规范关闭」：不要自动拉起，等用户自己点「启动」
		if a.stoppedByUser() {
			missed = 0
			continue
		}
		if a.runningPid() != 0 {
			missed = 0
			continue
		}
		// 与接口操作互斥：同一时刻只允许一个启动/停止流程
		if !a.opsMu.TryLock() {
			continue
		}
		missed = a.watchdogTickLocked(missed)
		a.opsMu.Unlock()
	}
}

// watchdogTickLocked 在持有 opsMu 的前提下做一次看护判断，返回更新后的连续未运行次数。
func (a *App) watchdogTickLocked(missed int) int {
	if a.runningPid() != 0 {
		return 0
	}
	missed++
	log.Printf("[看护] fwclient 未运行（第 %d/3 次检测）", missed)
	if missed < 3 { // 连续 3 次（约 30 秒）未运行才重连，避免启动期误判
		return missed
	}

	// 调用方已持有 opsMu，这里只需再拿跨进程锁；拿到后重新确认一次状态
	lk := a.lockStart()
	defer lk.release()
	if pid := a.runningPid(); pid != 0 {
		a.reapStrayDaemons(pid)
		return 0
	}
	log.Printf("[看护] 尝试自动重连")
	a.reapStrayDaemons(0)
	if err := a.spawnLocked(); err != nil {
		log.Printf("[看护] 自动重连失败：%v", err)
	}
	return 0
}

// ---------------------------------------------------------------------------
// HTTP 接口
// ---------------------------------------------------------------------------

type statusResp struct {
	AppName     string   `json:"appName"`
	AppDisplay  string   `json:"appDisplay"`
	AppVersion  string   `json:"appVersion"`
	Running     bool     `json:"running"`
	PID         int      `json:"pid"`
	FWVersion   string   `json:"fwVersion"`
	Gateway     string   `json:"gateway"`
	TokenMasked string   `json:"tokenMasked"`
	HasToken    bool     `json:"hasToken"`
	Insecure    bool     `json:"insecure"`
	AutoStart   bool     `json:"autoStart"`
	AutoReconn  bool     `json:"autoReconn"`
	Stopped     bool     `json:"stoppedByUser"`
	DeviceID    string   `json:"deviceId"`
	LogFile     string   `json:"logFile"`
	LogSize     int64    `json:"logSize"`
	LastError   string   `json:"lastError"`
	Binary      string   `json:"binary"`
	Paths       []string `json:"paths"`
}

func maskToken(t string) string {
	if t == "" {
		return ""
	}
	if len(t) <= 8 {
		return strings.Repeat("*", len(t))
	}
	return t[:6] + strings.Repeat("*", len(t)-6)
}

func (a *App) readDeviceID() string {
	raw, err := os.ReadFile(a.paths.IDFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	cfg := a.loadConfig()
	pid := a.runningPid()
	running := pid != 0
	_, logSize, _ := a.tailLog(0)

	paths := []string{}
	for _, d := range []string{a.paths.PkgEtc, a.paths.PkgVar, a.paths.RunDir, filepath.Dir(a.paths.Binary)} {
		if d != "" {
			paths = append(paths, d)
		}
	}

	resp := statusResp{
		AppName:     appName,
		AppDisplay:  appDisplay,
		AppVersion:  appVersion,
		Running:     running,
		PID:         pid,
		FWVersion:   a.version(false),
		Gateway:     cfg.Gateway,
		TokenMasked: maskToken(cfg.Token),
		HasToken:    cfg.Token != "",
		Insecure:    cfg.Insecure,
		AutoStart:   cfg.AutoStart,
		AutoReconn:  cfg.AutoReconn,
		Stopped:     a.stoppedByUser(),
		DeviceID:    a.readDeviceID(),
		LogFile:     a.paths.LogFile,
		LogSize:     logSize,
		Binary:      a.paths.Binary,
		Paths:       paths,
	}
	a.mu.Lock()
	resp.LastError = a.lastError
	a.mu.Unlock()

	writeJSON(w, 0, "ok", resp)
}

func (a *App) handleConfigSave(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Gateway    *string `json:"gateway"`
		Token      *string `json:"token"`
		Insecure   *bool   `json:"insecure"`
		VerifyTLS  *bool   `json:"verifyTls"`
		AutoStart  *bool   `json:"autoStart"`
		AutoReconn *bool   `json:"autoReconn"`
		Restart    *bool   `json:"restart"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, 1, "请求格式错误", nil)
		return
	}
	// 前端以「校验 TLS 证书」表述，这里换算成 fwclient 的 -insecure 语义
	if req.VerifyTLS != nil {
		v := !*req.VerifyTLS
		req.Insecure = &v
	}

	cfg := a.loadConfig()
	restartNeeded := false

	if req.Gateway != nil {
		g := strings.TrimSpace(*req.Gateway)
		if err := validateGateway(g); err != nil {
			writeJSON(w, 1, err.Error(), nil)
			return
		}
		if g != cfg.Gateway {
			cfg.Gateway = g
			restartNeeded = true
		}
	}
	if req.Token != nil {
		t := strings.TrimSpace(*req.Token)
		if t != "" { // 空值表示不修改令牌
			if err := validateToken(t); err != nil {
				writeJSON(w, 1, err.Error(), nil)
				return
			}
			if t != cfg.Token {
				cfg.Token = t
				restartNeeded = true
			}
		}
	}
	if req.Insecure != nil && *req.Insecure != cfg.Insecure {
		cfg.Insecure = *req.Insecure
		restartNeeded = true
	}
	if req.AutoStart != nil {
		cfg.AutoStart = *req.AutoStart
	}
	if req.AutoReconn != nil {
		cfg.AutoReconn = *req.AutoReconn
	}

	if err := a.saveConfig(cfg); err != nil {
		writeJSON(w, 1, "保存配置失败："+err.Error(), nil)
		return
	}

	msg := "配置已保存"
	running := a.runningPid() != 0
	valid := validateGateway(cfg.Gateway) == nil && validateToken(cfg.Token) == nil
	switch {
	case !valid:
		// 配置还不完整，不动客户端
	case running && restartNeeded:
		if err := a.restart(); err != nil {
			a.setUpgradeError(err.Error())
			writeJSON(w, 2, "配置已保存，但重连失败："+err.Error(), nil)
			return
		}
		msg = "配置已保存，客户端已使用新配置重连"
	case !running && cfg.AutoStart:
		// 客户端此前未运行：保存即尝试连接，省去用户再点一次启动；
		// 成功启动会清掉「手动停止」标记，看护线程恢复自动重连
		if err := a.startSerialized(); err != nil {
			log.Printf("[配置] 保存后自动连接失败：%v", err)
		} else {
			msg = "配置已保存，客户端已启动"
		}
	}
	writeJSON(w, 0, msg, nil)
}

func (a *App) handleStart(w http.ResponseWriter, r *http.Request) {
	if pid := a.runningPid(); pid != 0 {
		// 已经在运行：顺手收敛 pid 文件之外的重复进程，避免它们一直残留下去
		a.opsMu.Lock()
		a.reapStrayDaemons(pid)
		a.opsMu.Unlock()
		writeJSON(w, 0, "客户端已在运行", nil)
		return
	}
	cfg := a.loadConfig()
	if err := validateGateway(cfg.Gateway); err != nil {
		writeJSON(w, 1, "请先配置网关域名", nil)
		return
	}
	if err := validateToken(cfg.Token); err != nil {
		writeJSON(w, 1, "请先配置访问令牌", nil)
		return
	}
	if err := a.startSerialized(); err != nil {
		a.setUpgradeError(err.Error())
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	writeJSON(w, 0, "客户端已启动", nil)
}

func (a *App) handleStop(w http.ResponseWriter, r *http.Request) {
	err := a.stop()
	if errors.Is(err, errUngracefulStop) {
		// 进程已经结束，只是没走成 -k 的规范流程，对用户仍算停止成功
		writeJSON(w, 0, "客户端已停止（规范关闭未生效，已用信号结束进程）", nil)
		return
	}
	if err != nil {
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	writeJSON(w, 0, "客户端已规范关闭", nil)
}

func (a *App) handleRestart(w http.ResponseWriter, r *http.Request) {
	if err := a.restart(); err != nil {
		a.setUpgradeError(err.Error())
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	writeJSON(w, 0, "客户端已重启", nil)
}

func (a *App) handleLogs(w http.ResponseWriter, r *http.Request) {
	lines := 300
	if v := r.URL.Query().Get("lines"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 3000 {
			lines = n
		}
	}
	content, size, err := a.tailLog(lines)
	if err != nil {
		writeJSON(w, 1, "读取日志失败："+err.Error(), nil)
		return
	}
	writeJSON(w, 0, "ok", map[string]any{
		"file":    a.paths.LogFile,
		"size":    size,
		"lines":   content,
		"updated": time.Now().Format("15:04:05"),
	})
}

func (a *App) handleLogsClear(w http.ResponseWriter, r *http.Request) {
	if err := os.Truncate(a.paths.LogFile, 0); err != nil && !os.IsNotExist(err) {
		writeJSON(w, 1, "清空日志失败："+err.Error(), nil)
		return
	}
	writeJSON(w, 0, "日志已清空", nil)
}

func (a *App) handleVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 0, "ok", map[string]any{
		"appVersion": appVersion,
		"fwVersion":  a.version(r.URL.Query().Get("refresh") == "1"),
		"binary":     a.paths.Binary,
	})
}

func (a *App) handleUpgrade(w http.ResponseWriter, r *http.Request) {
	cfg := a.loadConfig()
	if a.runningPid() != 0 && !cfg.AutoReconn {
		// 升级不强制要求停止，fwclient 自身支持热替换后重启
		log.Printf("[升级] 客户端正在运行，升级完成后将自动加载新版本")
	}
	if err := a.startUpgrade(); err != nil {
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	writeJSON(w, 0, "已开始检查更新", nil)
}

func (a *App) handleUpgradeStatus(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	running := a.upgradeRunning
	out := append([]string{}, a.upgradeLog...)
	a.mu.Unlock()
	writeJSON(w, 0, "ok", map[string]any{
		"running": running,
		"output":  out,
		"version": a.version(false),
	})
}

// decodeOutput 把子进程输出整理成可安全展示给前端的字符串：
// 去掉 ANSI 转义序列，并把非法 UTF-8 字节替换掉。
var ansiRe = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]")

func decodeOutput(b []byte) string {
	s := ansiRe.ReplaceAllString(string(b), "")
	s = strings.ToValidUTF8(s, "")
	// 去掉除换行、制表符以外的控制字符
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || r >= 0x20 {
			return r
		}
		return -1
	}, s)
	return strings.TrimRight(s, "\r\n")
}

func writeJSON(w http.ResponseWriter, code int, msg string, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"code": code,
		"msg":  msg,
		"data": data,
	})
}

// ---------------------------------------------------------------------------
// 静态资源
// ---------------------------------------------------------------------------

//go:embed ui
var uiFS embed.FS

func (a *App) routes() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/status", a.handleStatus)
	mux.HandleFunc("/api/config", a.handleConfigSave)
	mux.HandleFunc("/api/start", a.handleStart)
	mux.HandleFunc("/api/stop", a.handleStop)
	mux.HandleFunc("/api/restart", a.handleRestart)
	mux.HandleFunc("/api/logs", a.handleLogs)
	mux.HandleFunc("/api/logs/clear", a.handleLogsClear)
	mux.HandleFunc("/api/version", a.handleVersion)
	mux.HandleFunc("/api/upgrade", a.handleUpgrade)
	mux.HandleFunc("/api/upgrade/status", a.handleUpgradeStatus)
	mux.HandleFunc("/api/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 0, "ok", map[string]any{"app": appName, "version": appVersion})
	})

	sub, err := fs.Sub(uiFS, "ui")
	if err != nil {
		log.Fatalf("内嵌页面资源不可用：%v", err)
	}
	mux.Handle("/", http.FileServer(http.FS(sub)))
	return mux
}

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------

func main() {
	p := resolvePaths()
	app := NewApp(p)
	app.ensureLayout()

	logDir := p.PkgVar
	_ = os.MkdirAll(logDir, 0o755)
	backendLog, err := os.OpenFile(filepath.Join(logDir, "backend.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err == nil {
		defer backendLog.Close()
		log.SetOutput(backendLog)
	}
	log.Printf("[后端] 启动 %s %s (pid=%d)", appName, appVersion, os.Getpid())
	log.Printf("[后端] 程序=%s 配置=%s 运行目录=%s 日志=%s", p.Binary, p.Config, p.RunDir, p.LogFile)

	// 提示配置来源（首次安装由向导写入）
	cfg := app.loadConfig()
	if cfg.Gateway == "" || cfg.Token == "" {
		log.Printf("[后端] 尚未配置网关域名或令牌")
	}

	port := env("TRIM_SERVICE_PORT", env("FWCLIENT_PORT", "18443"))
	addr := net.JoinHostPort(env("FWCLIENT_BIND", "0.0.0.0"), port)

	// 应用启动时按配置自动连接
	if cfg.AutoStart && cfg.Gateway != "" && cfg.Token != "" {
		if err := app.startSerialized(); err != nil {
			log.Printf("[后端] 自动连接失败：%v", err)
			app.setUpgradeError(err.Error())
		}
	}

	go app.watchdog()

	srv := &http.Server{
		Addr:              addr,
		Handler:           app.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("[后端] 监听 %s", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("[后端] 服务退出：%v", err)
	}
}
