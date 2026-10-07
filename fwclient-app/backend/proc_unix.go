//go:build !windows

package main

import (
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// syscallSignalZero 用于探测进程是否存活。
var syscallSignalZero = syscall.Signal(0)

// terminateSignal 用于请求进程正常退出。
var terminateSignal = syscall.SIGTERM

// startLock 是跨进程启动互斥锁，底层是 flock。
type startLock struct {
	f *os.File
}

// acquireStartLock 以 flock 排他锁获取启动锁，超时返回错误。
//
// 锁文件用只读方式打开：flock 对只读 fd 同样有效，而锁文件通常由 root 生命周期
// 脚本创建（0644），包用户只能只读打开——这样两边都能正确加锁。
func acquireStartLock(path string, timeout time.Duration) (*startLock, error) {
	if path == "" {
		return nil, os.ErrInvalid
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDONLY, 0o644)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return &startLock{f: f}, nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			break
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = f.Close()
	return nil, err
}

// release 释放启动锁；锁为 nil 时安全跳过。
func (l *startLock) release() {
	if l == nil || l.f == nil {
		return
	}
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
	l.f = nil
}

// lookupUser 解析用户 uid/gid。
func lookupUser(name string) (int, int, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return 0, 0, err
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return 0, 0, err
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return 0, 0, err
	}
	return uid, gid, nil
}

// sysProcAttrForUser 生成降权所需的进程属性。
func sysProcAttrForUser(uid, gid int) *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)},
	}
}

// daemonPids 扫描 /proc，找出所有属于本应用的 fwclient 守护进程。
//
// 只信 pid 文件是不够的：竞态会同时拉起两个客户端，而 pid 文件只记录后写入的
// 那个，其余进程既停不掉也看不见。这里按「可执行文件 + 运行目录」识别，
// 并排除 -k / -v / -u 这类一次性子进程。
func daemonPids(bin, runDir string) []int {
	if bin == "" || runDir == "" {
		return nil
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	self := os.Getpid()
	base := filepath.Base(bin)
	var pids []int

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 || pid == self {
			continue
		}
		raw, err := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
		if err != nil {
			continue
		}
		argv := splitArgv(raw)
		if len(argv) == 0 {
			continue
		}
		if argv[0] != bin && filepath.Base(argv[0]) != base {
			continue
		}
		if isOneShotClient(argv) || !hasRunDirArg(argv, runDir) {
			continue
		}
		pids = append(pids, pid)
	}
	return pids
}

// splitArgv 把 /proc/<pid>/cmdline 的 NUL 分隔内容切成参数列表。
func splitArgv(raw []byte) []string {
	parts := strings.Split(string(raw), "\x00")
	out := parts[:0]
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// isOneShotClient 判断是否是一次性命令（不是常驻守护进程）。
func isOneShotClient(argv []string) bool {
	for _, a := range argv[1:] {
		switch a {
		case "-k", "-v", "-u", "-h", "-help", "--help":
			return true
		}
	}
	return false
}

// hasRunDirArg 判断参数里是否明确指定了本应用的运行目录。
func hasRunDirArg(argv []string, runDir string) bool {
	for i, a := range argv {
		if a == "-dir" && i+1 < len(argv) && argv[i+1] == runDir {
			return true
		}
		if a == "-dir="+runDir {
			return true
		}
	}
	return false
}
