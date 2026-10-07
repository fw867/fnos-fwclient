// 应用自身更新：查 GitHub Releases → 下载 .fpk → 校验 → 尝试调用 fnOS 的 appcenter-cli 安装。
//
// 背景：应用以包用户（run-as=package）运行，没有 root 权限，绝大多数情况下
// 无法直接安装系统级应用包。因此这里的策略是「能自动就自动，不能自动就引导」：
//  1. 只从本仓库的 Release 里取包，不接受外部路径，避免被当成任意安装入口；
//  2. 下载后按 Release 里的 SHA256SUMS.txt 校验；
//  3. 尝试执行 appcenter-cli install-fpk，成功即完成升级；
//  4. 权限不足或没有该命令时，返回已下载的路径，由页面提示到应用中心手动安装。
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type releaseAsset struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"browser_download_url"`
}

type releaseInfo struct {
	TagName     string         `json:"tag_name"`
	Body        string         `json:"body"`
	PublishedAt string         `json:"published_at"`
	HTMLURL     string         `json:"html_url"`
	Assets      []releaseAsset `json:"assets"`
}

type updateStatus struct {
	Current     string `json:"current"`
	Latest      string `json:"latest"`
	HasUpdate   bool   `json:"hasUpdate"`
	PublishedAt string `json:"publishedAt"`
	Notes       string `json:"notes"`
	ReleaseURL  string `json:"releaseUrl"`
	AssetName   string `json:"assetName"`
	AssetSize   int64  `json:"assetSize"`
	AssetURL    string `json:"assetUrl"`
	Repo        string `json:"repo"`

	Downloaded   string `json:"downloaded"`
	DownloadedOK bool   `json:"downloadedOk"`
	Installable  bool   `json:"installable"` // 系统里是否有 appcenter-cli
	Error        string `json:"error,omitempty"`
}

// appcenterCandidates 是 fnOS 应用中心 CLI 的常见位置（优先 PATH）。
var appcenterCandidates = []string{
	"appcenter-cli",
	"/usr/bin/appcenter-cli",
	"/usr/local/bin/appcenter-cli",
	"/usr/sbin/appcenter-cli",
	"/usr/trim/bin/appcenter-cli",
	"/vol1/@sys/usr/bin/appcenter-cli",
}

func (a *App) updateRepo() string {
	return env("FWCLIENT_REPO", "fw867/fnos-fwclient")
}

// latestRelease 查询最新 Release，结果缓存 10 分钟，避免触发 GitHub 限流。
func (a *App) latestRelease(force bool) (*releaseInfo, error) {
	a.updMu.Lock()
	defer a.updMu.Unlock()

	if !force && a.updCache != nil && time.Since(a.updAt) < 10*time.Minute {
		return a.updCache, nil
	}

	url := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", a.updateRepo())
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "fwclient-fnos-app")

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("访问 GitHub 失败：%w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 512*1024))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub 返回 %d（可能触发限流，稍后再试）", resp.StatusCode)
	}

	var rel releaseInfo
	if err := json.Unmarshal(body, &rel); err != nil {
		return nil, fmt.Errorf("解析 GitHub 返回失败：%w", err)
	}
	if rel.TagName == "" {
		return nil, errors.New("GitHub 没有返回可用的版本标签")
	}
	a.updCache = &rel
	a.updAt = time.Now()
	return &rel, nil
}

func trimVersion(tag string) string {
	return strings.TrimPrefix(strings.TrimSpace(tag), "v")
}

// versionGreater 判断 a 是否比 b 新（按 X.Y.Z 数值比较）。
// 解析不出来时退回「不相等即视为有更新」，避免因版本号格式特殊漏掉更新，
// 但正常情况下不会把更低版本当成更新。
func versionGreater(a, b string) bool {
	pa, oka := parseSemver(a)
	pb, okb := parseSemver(b)
	if !oka || !okb {
		return a != "" && a != b
	}
	for i := 0; i < 3; i++ {
		if pa[i] != pb[i] {
			return pa[i] > pb[i]
		}
	}
	return false
}

func parseSemver(s string) ([3]int, bool) {
	var out [3]int
	parts := strings.Split(trimVersion(s), ".")
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		digits := ""
		for _, r := range p {
			if r < '0' || r > '9' {
				break
			}
			digits += string(r)
		}
		if digits == "" {
			return out, false
		}
		n, err := strconv.Atoi(digits)
		if err != nil {
			return out, false
		}
		out[i] = n
	}
	return out, true
}

func pickAssets(rel *releaseInfo) (pkg, sums *releaseAsset) {
	for i := range rel.Assets {
		name := rel.Assets[i].Name
		switch {
		case strings.HasSuffix(name, ".fpk"):
			pkg = &rel.Assets[i]
		case name == "SHA256SUMS.txt":
			sums = &rel.Assets[i]
		}
	}
	return pkg, sums
}

func (a *App) updateDir() string {
	return filepath.Join(a.paths.PkgVar, "update")
}

// appcenterPath 返回可用的 appcenter-cli 路径，没有则返回空。
func appcenterPath() string {
	for _, c := range appcenterCandidates {
		if strings.Contains(c, string(os.PathSeparator)) {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				return c
			}
			continue
		}
		if p, err := exec.LookPath(c); err == nil {
			return p
		}
	}
	return ""
}

// downloadPackage 把最新版本的 .fpk 下载到应用数据目录并校验 SHA256。
func (a *App) downloadPackage(rel *releaseInfo) (string, error) {
	pkg, sums := pickAssets(rel)
	if pkg == nil {
		return "", errors.New("最新版本里没有 .fpk 产物")
	}

	dir := a.updateDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("创建下载目录失败：%w", err)
	}
	dst := filepath.Join(dir, filepath.Base(pkg.Name))

	// 已经下载过且大小一致就直接复用
	if st, err := os.Stat(dst); err == nil && pkg.Size > 0 && st.Size() == pkg.Size {
		return dst, nil
	}

	tmp := dst + ".part"
	if err := downloadFile(pkg.URL, tmp); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}

	if sums != nil {
		want, err := remoteChecksum(sums.URL, pkg.Name)
		if err != nil {
			return "", err
		}
		got, err := fileSHA256(tmp)
		if err != nil {
			return "", err
		}
		if !strings.EqualFold(want, got) {
			_ = os.Remove(tmp)
			return "", fmt.Errorf("校验失败：期望 %s，实际 %s", want[:12], got[:12])
		}
		log.Printf("更新包校验通过：%s (%s)", pkg.Name, got[:12])
	}

	if err := os.Rename(tmp, dst); err != nil {
		return "", err
	}
	_ = os.Chmod(dst, 0o644)
	return dst, nil
}

func downloadFile(url, dst string) error {
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("下载失败：%w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("下载失败：HTTP %d", resp.StatusCode)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func remoteChecksum(url, name string) (string, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("读取校验和失败：%w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.HasSuffix(fields[1], name) {
			return fields[0], nil
		}
	}
	return "", errors.New("校验和文件里没有找到对应产物")
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// installPackage 尝试用 fnOS 的 appcenter-cli 安装已下载的包。
func installPackage(path string) (string, error) {
	bin := appcenterPath()
	if bin == "" {
		return "", errors.New("系统里没有 appcenter-cli，无法在应用内自动安装")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, "install-fpk", path)
	out, err := cmd.CombinedOutput()
	text := decodeOutput(out)
	if err != nil {
		if text == "" {
			text = err.Error()
		}
		return text, fmt.Errorf("appcenter-cli 执行失败：%w", err)
	}
	return text, nil
}

// --- HTTP 接口 --------------------------------------------------------------

func (a *App) handleAppUpdate(w http.ResponseWriter, r *http.Request) {
	force := r.URL.Query().Get("refresh") == "1"
	rel, err := a.latestRelease(force)

	status := updateStatus{
		Current:     appVersion,
		Repo:        a.updateRepo(),
		Installable: appcenterPath() != "",
	}
	if err != nil {
		status.Error = err.Error()
		writeJSON(w, 1, err.Error(), status)
		return
	}

	pkg, _ := pickAssets(rel)
	status.Latest = trimVersion(rel.TagName)
	status.PublishedAt = rel.PublishedAt
	status.Notes = rel.Body
	status.ReleaseURL = rel.HTMLURL
	status.HasUpdate = versionGreater(status.Latest, appVersion)
	if pkg != nil {
		status.AssetName = pkg.Name
		status.AssetSize = pkg.Size
		status.AssetURL = pkg.URL
	}

	// 已经下载好的包（同名同大小）直接标出来
	if pkg != nil {
		local := filepath.Join(a.updateDir(), filepath.Base(pkg.Name))
		if st, err := os.Stat(local); err == nil && (pkg.Size == 0 || st.Size() == pkg.Size) {
			status.Downloaded = local
			status.DownloadedOK = true
		}
	}
	writeJSON(w, 0, "ok", status)
}

func (a *App) handleAppDownload(w http.ResponseWriter, r *http.Request) {
	rel, err := a.latestRelease(true)
	if err != nil {
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	path, err := a.downloadPackage(rel)
	if err != nil {
		a.setUpgradeError(err.Error())
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	pkg, _ := pickAssets(rel)
	msg := fmt.Sprintf("已下载 %s 到 %s", filepath.Base(path), path)
	if pkg != nil && pkg.Name != "" {
		msg = fmt.Sprintf("已下载并校验 %s（%.1f MB）", pkg.Name, float64(pkg.Size)/1024/1024)
	}
	log.Printf("[应用更新] %s", msg)
	writeJSON(w, 0, msg, map[string]any{"path": path, "version": trimVersion(rel.TagName)})
}

// handleAppInstall 只安装自己下载好的那个包：不接受路径参数，
// 避免把接口变成「任意 fpk 安装入口」。
func (a *App) handleAppInstall(w http.ResponseWriter, r *http.Request) {
	rel, err := a.latestRelease(false)
	if err != nil {
		writeJSON(w, 1, err.Error(), nil)
		return
	}
	pkg, _ := pickAssets(rel)
	if pkg == nil {
		writeJSON(w, 1, "最新版本里没有 .fpk 产物", nil)
		return
	}
	local := filepath.Join(a.updateDir(), filepath.Base(pkg.Name))
	if _, err := os.Stat(local); err != nil {
		writeJSON(w, 1, "还没有下载好安装包，请先点「下载最新版」", nil)
		return
	}

	out, err := installPackage(local)
	if err != nil {
		log.Printf("[应用更新] 自动安装失败：%v（输出：%s）", err, out)
		writeJSON(w, 2, fmt.Sprintf("%v。请在应用中心「手动安装」选择已下载的包：%s", err, local),
			map[string]any{"path": local, "output": out})
		return
	}
	log.Printf("[应用更新] 自动安装完成：%s", out)
	writeJSON(w, 0, "升级指令已提交，应用即将重启，稍后刷新页面", map[string]any{"path": local, "output": out})
}
