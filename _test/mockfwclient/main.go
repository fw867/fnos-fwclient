// mockfwclient 仅用于本地自测：模拟 fwclient 的命令行行为，
// 不参与应用打包。行为对齐真实客户端：
//
//	-d            守护进程化：脱离父进程写 pid 文件，持续输出日志
//	-k            规范关闭：读取 pid 文件结束进程并清理
//	-v            打印版本号
//	-u            检查并升级
//	-dir          运行数据目录（pid / 日志 / 设备标识）
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const mockVersion = "v1.3.1-mock"

func pidPath(dir string) string  { return filepath.Join(dir, "fwclient.pid") }
func logPath(dir string) string  { return filepath.Join(dir, "fwclient.log") }
func idPath(dir string) string   { return filepath.Join(dir, "fwclient.id") }

func readPid(dir string) int {
	raw, err := os.ReadFile(pidPath(dir))
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return 0
	}
	return n
}

func appendLog(dir, format string, args ...any) {
	f, err := os.OpenFile(logPath(dir), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	stamp := time.Now().Format("2006-01-02 15:04:05")
	fmt.Fprintf(f, "%s %s\n", stamp, fmt.Sprintf(format, args...))
}

func ensureID(dir string) {
	if _, err := os.Stat(idPath(dir)); err == nil {
		return
	}
	_ = os.WriteFile(idPath(dir), []byte("mock-device-0123456789abcdef\n"), 0o600)
}

func main() {
	var (
		server   = flag.String("s", "", "服务器")
		token    = flag.String("t", "", "令牌")
		daemon   = flag.Bool("d", false, "后台运行")
		kill     = flag.Bool("k", false, "规范关闭")
		upgrade  = flag.Bool("u", false, "检查升级")
		version  = flag.Bool("v", false, "版本号")
		dir      = flag.String("dir", "", "运行数据目录")
	)
	flag.Parse()

	runDir := *dir
	if runDir == "" {
		runDir = filepath.Dir(os.Args[0])
	}
	_ = os.MkdirAll(runDir, 0o755)

	switch {
	case *version:
		fmt.Printf("fwclient %s (windows/amd64)\n", mockVersion)
		return

	case *kill:
		pid := readPid(runDir)
		if pid == 0 {
			fmt.Println("没有正在运行的 fwclient.")
			return
		}
		fmt.Printf("规范关闭正在运行的客户端 (pid %d)...\n", pid)
		if p, err := os.FindProcess(pid); err == nil {
			_ = exec.Command("taskkill", "/PID", strconv.Itoa(pid), "/T", "/F").Run()
			_ = p.Release()
		}
		_ = os.Remove(pidPath(runDir))
		fmt.Printf("已规范关闭 fwclient (pid %d).\n", pid)
		return

	case *upgrade:
		fmt.Printf("当前版本 %s.\n", mockVersion)
		for i := 1; i <= 3; i++ {
			fmt.Printf("正在下载并替换二进制... %d/3\n", i)
			time.Sleep(600 * time.Millisecond)
		}
		fmt.Println("已是最新版本 " + mockVersion)
		fmt.Println("[更新] 升级完成. " + mockVersion + " . 正在重启...")
		return
	}

	if *server == "" || *token == "" {
		fmt.Fprintln(os.Stderr, "错误: 必须提供 -s 服务器 与 -t 令牌")
		os.Exit(1)
	}

	ensureID(runDir)
	appendLog(runDir, "[客户端] 首次运行.已生成设备标识 %s", idPath(runDir))

	if !*daemon {
		appendLog(runDir, "[客户端] 前台运行，按 Ctrl+C 结束")
		for i := 0; ; i++ {
			appendLog(runDir, "[客户端] 服务端 %s (CONNECT :443) | 设备 mock-device | 心跳 %d", *server, i)
			time.Sleep(2 * time.Second)
		}
	}

	// 模拟 daemonize：起一个子进程后父进程退出
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	child := exec.Command(self, "-s", *server, "-t", *token, "-dir", runDir)
	child.Stdout = nil
	child.Stderr = nil
	if err := child.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "daemonize 失败:", err)
		os.Exit(1)
	}
	_ = os.WriteFile(pidPath(runDir), []byte(strconv.Itoa(child.Process.Pid)+"\n"), 0o600)
	appendLog(runDir, "[客户端] 启动 fwclient %s (windows/amd64)", mockVersion)
	appendLog(runDir, "[客户端] 服务端 %s (CONNECT :443) | 设备 mock-device", *server)
	appendLog(runDir, "fwclient 已守护运行 (pid %d).日志见 %s.", child.Process.Pid, logPath(runDir))
	fmt.Printf("fwclient 已守护运行 (pid %d).日志见 %s.\n", child.Process.Pid, logPath(runDir))
	_ = child.Process.Release()
}
