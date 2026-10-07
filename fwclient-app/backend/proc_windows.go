//go:build windows

package main

import "syscall"

// syscallSignalZero 在 Windows 上不使用，保留占位以复用同一份逻辑。
var syscallSignalZero = syscall.Signal(0)

// terminateSignal 在 Windows 上同样使用 Kill 兜底。
var terminateSignal = syscall.Signal(9)

// lookupUser 在 Windows 上不支持降权。
func lookupUser(name string) (int, int, error) {
	return 0, 0, nil
}

// sysProcAttrForUser 在 Windows 上返回空属性。
func sysProcAttrForUser(uid, gid int) *syscall.SysProcAttr {
	return nil
}
