//go:build windows

package main

import (
	"syscall"
	"time"
)

// syscallSignalZero 在 Windows 上不使用，保留占位以复用同一份逻辑。
var syscallSignalZero = syscall.Signal(0)

// terminateSignal 在 Windows 上同样使用 Kill 兜底。
var terminateSignal = syscall.Signal(9)

// startLock 在 Windows 上是空实现（自测时用 mock 客户端，不需要跨进程互斥）。
type startLock struct{}

// acquireStartLock 在 Windows 上不做加锁，直接返回空锁。
func acquireStartLock(path string, timeout time.Duration) (*startLock, error) {
	return &startLock{}, nil
}

// release 空实现。
func (l *startLock) release() {}

// daemonPids 在 Windows 上不支持扫描 /proc，返回空（退回 pid 文件判断）。
func daemonPids(bin, runDir string) []int {
	return nil
}

// lookupUser 在 Windows 上不支持降权。
func lookupUser(name string) (int, int, error) {
	return 0, 0, nil
}

// sysProcAttrForUser 在 Windows 上返回空属性。
func sysProcAttrForUser(uid, gid int) *syscall.SysProcAttr {
	return nil
}
