//go:build !windows

package main

import (
	"os/user"
	"strconv"
	"syscall"
)

// syscallSignalZero 用于探测进程是否存活。
var syscallSignalZero = syscall.Signal(0)

// terminateSignal 用于请求进程正常退出。
var terminateSignal = syscall.SIGTERM

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
