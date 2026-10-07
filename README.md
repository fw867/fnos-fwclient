# 内网穿透（fwclient）· 飞牛 fnOS 应用

[![构建与发布](https://github.com/fw867/fnos-fwclient/actions/workflows/release.yml/badge.svg)](https://github.com/fw867/fnos-fwclient/actions/workflows/release.yml)
[![最新版本](https://img.shields.io/github/v/release/fw867/fnos-fwclient?label=release)](https://github.com/fw867/fnos-fwclient/releases)

把 fw867 的 `fwclient` 内网穿透客户端封装成飞牛 fnOS 原生应用：装好后在**应用设置**里填写
网关域名和访问令牌，桌面打开「内网穿透」即可看运行状态、实时日志、当前版本，并一键升级客户端。

- 应用包名：`fwclient`
- 显示名称：内网穿透
- 版本：`1.0.3`
- 架构：x86_64（`platform=x86`）
- 管理页面端口：`18443`

---

## 1. 功能

| 功能 | 说明 |
| --- | --- |
| 页面结构 | 两个 tab：「运行状态」（状态卡片 + 运行日志）、「应用配置」（连接配置），标签页记忆上次选择 |
| 网关域名 / 令牌配置 | 安装向导、应用设置向导、网页管理页三处均可修改，令牌留空表示不修改 |
| 客户端启停 | 状态卡片里依次是启动、规范关闭（`fwclient -k`）、重启、检查并升级；手动停止后不会被自动重连拉起，异常退出仍会自动重连 |
| 实时日志 | 读取 `fwclient` 日志尾部，支持 100/300/1000/3000 行、4 秒自动刷新、清空 |
| 版本显示 | 调用 `fwclient -v`，当前版本直接显示在状态卡片里，无需单独查询 |
| 一键升级 | 状态卡片里的「检查并升级」调用 `fwclient -u`，进度显示在状态提示行，升级后自动刷新版本 |
| 设备标识保留 | 升级、卸载（默认）均保留 `fwclient.id`，避免服务端把设备当成新机器 |
| 开机自启 | 应用启动时按配置自动连接；可在「应用配置」中关闭 |

## 2. 目录结构

```
.
├── fwclient-app/                 # 应用包源码（fnpack 打包输入）
│   ├── manifest                  # 应用元数据
│   ├── ICON.PNG / ICON_256.PNG   # 包图标 64 / 256
│   ├── app/                      # 运行文件（打包为 app.tgz）
│   │   ├── bin/fwclient          # 官方 fwclient（linux x86_64）
│   │   ├── server/fwclient-server# 管理后端（Go 交叉编译产物）
│   │   └── ui/                   # 桌面入口配置与入口图标
│   ├── backend/                  # 管理后端源码（Go，仅标准库，不参与打包）
│   │   ├── main.go
│   │   ├── proc_unix.go / proc_windows.go
│   │   └── ui/                   # 内嵌到二进制的管理页面
│   ├── cmd/                      # 生命周期脚本
│   │   ├── lib.sh                # 公共函数（路径、配置、进程控制、程序定位）
│   │   ├── main                  # start / stop / status
│   │   ├── install_init|_callback
│   │   ├── upgrade_init|_callback
│   │   ├── config_init|_callback
│   │   └── uninstall_init|_callback
│   ├── config/                   # privilege / resource
│   └── wizard/                   # install / config / upgrade / uninstall 向导
├── dist/fwclient-1.0.3.fpk       # 打包产物（可直接安装）
├── build.sh                      # 一键构建
├── pack_fpk.py                   # 无 fnpack 时直接打包 .fpk（布局与 fnpack 一致）
├── repack_fpk.py                 # 打包后补回 Unix 可执行位
├── make_icons.py                 # 生成图标
└── _test/                        # 验证脚本（不参与打包）
```

## 3. 安装与使用

1. 把 `dist/fwclient-1.0.2.fpk` 上传到 fnOS，通过应用中心「手动安装」安装；
2. 安装向导中填写**网关域名**（例如 `fw867.com`）和**访问令牌**（`tk_...`）；
   「校验 TLS 证书」默认打开，只有网关使用自签证书、连接报证书错误时才关闭它；
3. 安装完成后应用会自动启动并连接；
4. 桌面 →「内网穿透」打开管理页面，可查看状态、日志、版本并一键升级；
5. 需要改配置时走「应用设置 → 连接配置」，保存后客户端会自动用新配置重连。

安装后的关键路径（`{appname}` 即 `fwclient`）：

| 用途 | 路径 |
| --- | --- |
| 配置 | `/var/apps/fwclient/etc/config.json`（`0600`） |
| 运行数据 | `/var/apps/fwclient/var/`，pid / 日志 / 设备标识在 `var/run/` |
| 生命周期日志 | `/var/apps/fwclient/var/lifecycle.log` |
| 管理后端日志 | `/var/apps/fwclient/var/backend.log` |
| 客户端日志 | `/var/apps/fwclient/var/run/fwclient.log` |
| 设备标识 | `/var/apps/fwclient/var/run/fwclient.id` |

## 4. 架构

```
fnOS 生命周期                    应用进程
──────────────                   ────────────────────────────────
cmd/main start  ──►  fwclient-server（管理后端，常驻，端口 18443）
                        │  HTTP 管理页 + REST 接口
                        ├─► fwclient -s <网关> -t <令牌> -dir <运行目录> -d
                        │      客户端守护进程（pid/日志/设备标识都在运行目录）
                        └─► 看护线程：进程异常退出 → 自动重连
```

- 生命周期脚本只负责「起停管理后端、写入配置、权限收敛」，不做长期驻留；
- 管理后端负责拉起、看护、规范关闭客户端，并提供页面与接口；
- **客户端进程由脚本与管理后端共同「兜底」拉起，因此必须跨进程互斥**：
  两边都会先读 `fwclient.pid` 判断「未运行」，而客户端写 pid 文件要几十毫秒，
  这个窗口里两边会各拉起一个守护进程——pid 文件只记录后写入的那个，
  另一个既停不掉也不会显示在状态里。现在两边都用 `var/fwclient.lock` 上的
  `flock` 把「判断 + 拉起」做成跨进程原子操作，启动、停止、重启还会顺手
  清理 pid 文件之外的重复/残留进程（历史遗留的重复进程也能自动收敛）；
- **管理后台拉起客户端时会带上 `-insecure`**，与脚本路径保持一致，
  否则自启动/页面启动会忽略「校验 TLS 证书」开关；
- **手动停止是「粘」的**：页面点「规范关闭」会写一个
  `TRIM_PKGVAR/client.stopped` 标记，看护线程读到它就不再自动重连
  （否则 30 秒后客户端又会被拉起来，看起来像「关不掉」）；
  点「启动/重启」、保存配置或应用重新启动时清掉该标记。
  状态接口用 `stoppedByUser` 字段暴露这个状态；
- 客户端的所有文件（pid / 日志 / 设备标识）统一放在 `TRIM_PKGVAR/run`，
  通过 `-dir` 一次性指定，卸载/迁移都不会散落到系统目录。

### HTTP 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/status` | 运行状态、PID、版本、设备标识、配置摘要、是否被手动停止（`stoppedByUser`） |
| POST | `/api/config` | 保存配置（`gateway` / `token` / `verifyTls` / `autoStart` / `autoReconn`） |
| POST | `/api/start` `/api/stop` `/api/restart` | 启停客户端 |
| GET | `/api/logs?lines=N` | 读取客户端日志尾部 |
| POST | `/api/logs/clear` | 清空客户端日志 |
| GET | `/api/version?refresh=1` | 查询版本（可强制刷新） |
| POST | `/api/upgrade` | 触发 `fwclient -u` |
| GET | `/api/upgrade/status` | 升级进度与输出 |
| GET | `/api/healthz` | 健康检查 |

> 接口兼容 `insecure` 字段：请求里给 `verifyTls` 会换算成 `insecure = !verifyTls`。

## 5. 重新构建

依赖：Go 1.22+、fnpack 1.2.3（放在 `_tools/fnpack.exe` 或设置 `FNPACK`）、
Python + Pillow（仅重新生成图标时需要）。

```bash
# 完整构建并打包（产出 dist/fwclient-<version>.fpk）
./build.sh

# 只准备 app 目录，不打包
./build.sh --no-pack
```

`build.sh` 会：规范化脚本换行符 → 交叉编译 `linux/amd64` 后端 →
校验包结构 → 打包（fnpack，或退回 `pack_fpk.py`）→ 用 `repack_fpk.py` 补回可执行位。

> fnpack 打包时会把文件权限统一写成 `0666`，而 fnOS 直接执行 `cmd/` 下的脚本，
> 所以打包后必须用 `repack_fpk.py` 重打包：`cmd/*` 设 `0755`，
> `app/bin/fwclient`、`app/server/fwclient-server` 设 `0755`。
> 没有 fnpack 时 `build.sh` 会自动改用 `pack_fpk.py`：产物布局与 fnpack 完全一致
> （`manifest` + 图标 + `app.tgz` + `cmd/` + `config/` + `wizard/`），
> 并且直接把可执行位写进归档，不需要再跑 `repack_fpk.py`。

手动分步：

```bash
cd fwclient-app/backend
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
    -o ../app/server/fwclient-server .
cd ../..
python pack_fpk.py fwclient-app dist/fwclient-1.0.3.fpk   # 无 fnpack 时
# 有 fnpack 时：python repack_fpk.py dist/fwclient-1.0.3.fpk
```

升级自带客户端：把新的 `fwclient`（linux x86_64）覆盖 `fwclient-app/app/bin/fwclient`，
提升 `manifest` 的 `version`，重新执行 `./build.sh`。

## 6. 验证

`_test/` 下的脚本在 WSL/Linux 中用**真实的 fwclient 二进制**跑通：

```bash
bash _test/verify_linux.sh      # 二进制可用性、后端接口、日志、启停、参数校验
bash _test/verify_lifecycle.sh  # install/config/start/status/stop 生命周期脚本
bash _test/verify_restart.sh    # 反复重启不产生孤儿进程、耗时
bash _test/verify_uninstall.sh  # 卸载时保留/删除设备标识两条分支
bash _test/verify_fixes.sh      # 安装前检查不阻断安装 + TLS 校验默认值语义
bash _test/verify_duplicate_start.sh  # 启动只会有一个客户端进程、重复进程自动收敛、手动停止标记
bash _test/verify_ui.sh         # 管理页 tab 结构、按钮顺序、已移除的卡片、前端元素引用
```

已在 WSL Ubuntu 中验证结果（合计 118 项全过）：

```
verify_linux            PASS=17 FAIL=0
verify_lifecycle        PASS=10 FAIL=0
verify_restart          PASS=11 FAIL=0
verify_uninstall        PASS=7  FAIL=0
verify_fixes            PASS=28 FAIL=0
verify_duplicate_start  PASS=22 FAIL=0
verify_ui               PASS=23 FAIL=0
```

> 说明：以上验证在 WSL 下以当前用户身份运行，未覆盖 fnOS 的
> `run-as=package` 用户切换、应用中心安装界面等系统侧行为，请在真机上再走一遍安装流程。

## 7. 已知行为与注意事项

- **首次连接**：安装后如未填配置，应用仍会启动管理页，填好网关域名与令牌保存即自动连接。
- **页面分两个 tab**：「运行状态」放状态卡片（启动 / 规范关闭 / 重启 / 检查并升级）与运行日志，
  「应用配置」放连接配置表单；升级进度显示在状态卡片的提示行里，不再单开输出窗口。
- **手动停止后不会被拉起**：点「规范关闭」后客户端保持停止，看护线程不会在 30 秒后自动重连；
  顶部状态会显示「已手动停止」，点「启动」或保存配置即可恢复。
  如果点了停止却还看到客户端在跑，多半是 1.0.3 之前版本留下的重复实例
  （停止流程现在会把它们一并清理）。
- **不会重复拉起客户端**：`cmd/main start` 与管理后端的自启动都会尝试拉起 `fwclient`，
  两边用 `var/fwclient.lock` 上的 `flock` 互斥，只会有一个客户端守护进程；
  启动、停止、重启时还会清理 `fwclient.pid` 之外的重复/残留进程。
- **管理后台不重复启动**：`cmd/main start` 发现管理后台已在运行时会直接复用，
  不会启动第二个进程（第二个会因端口占用退出并把 pid 文件覆盖成死进程）。
- **「开机自启」开关同时作用于脚本与后台**：关闭后，应用启动、配置变更都不会自动连接，
  仍可在管理页手动点「启动」。
- **规范关闭**：停止时优先执行 `fwclient -k -dir <运行目录>`（通知服务端断开后退出）；
  客户端未响应时退回 `SIGTERM`，两种情况都会在接口与日志中区分显示。
- **升级期间重启**：`fwclient -u` 替换二进制后，守护进程会在 1 分钟内自行重启加载新版本；
  若需要立即生效，可在管理页点「重启」。
- **设备标识**：`fwclient.id` 丢失会被服务端视为新设备，需在管理端重新配置穿透规则。
  应用在升级流程与卸载（默认选项）中都会保留它。
- **权限**：应用以专用包用户运行，不申请 root；客户端与管理后端的全部文件都落在应用目录内。
- **端口**：管理页固定使用 `18443`，`manifest` 中 `checkport=false`，避免与其它服务冲突时被拦截。
- **TLS 校验默认开启**：向导与网页里都是「校验 TLS 证书」这一正向开关，默认打开；
  只有用户主动关闭时才写入 `"insecure": true`（此时客户端带 `-insecure` 启动）。
  该开关对**所有**启动路径都生效：脚本拉起、后端自启动、页面「启动/重启」
  以及看护线程重连都会带上 `-insecure`。
- **安装前检查完全只读**：实测 fnOS 调用 `install_init` 时，`TRIM_APPDEST`
  （`/vol1/@appcenter/<app>`）尚未创建、`TRIM_PKGVAR`（`/vol1/@appdata/<app>`）也还不可写。
  因此这一步只做只读探测与布局记录，既不校验程序文件、也不校验目录可写——
  这两项都曾导致「无法安装」的误报。目录准备与硬校验放在
  `install_callback` 与 `cmd/main start`。
- **日志写入不报错**：`lifecycle.log` 所在目录不可写时静默跳过写入，
  避免 shell 的 `Permission denied` 被 fnOS 弹到安装界面上。
- **程序文件自动补位**：若文件不在预期位置，`cmd/lib.sh` 会在安装临时目录、
  `/var/apps/<appname>` 等位置查找并补齐，同时把目录结构写进 `lifecycle.log` 便于排查。

## 8. 排查安装/启动问题

生命周期日志：`/var/apps/fwclient/var/lifecycle.log`（安装、配置、启动、停止都会写）。

需要在设备侧核对实际布局时：

```bash
ls -l /var/apps/fwclient/ /var/apps/fwclient/target/ 2>/dev/null
tail -n 50 /var/apps/fwclient/var/lifecycle.log 2>/dev/null
```

核对进程（正常应当只有 `fwclient-server` 与 `fwclient` 各一个；若 `fwclient`
多于一个，说明是 1.0.3 之前版本留下的重复进程，重启一次应用会自动收敛）：

```bash
ps -eo pid,ppid,args | grep -E 'app/(bin|server)/fwclient' | grep -v grep
cat /var/apps/fwclient/var/run/fwclient.pid
```

## 9. 自动构建与发布（GitHub Actions）

不用手动改版本号，也不用打标签：**提交信息里带 `[release]` 就会自动发版**。

```bash
# 普通提交：什么都不跑
git commit -am "fix: 调整日志文案"

# 发布提交：自动累加版本号 + 打包 + 验证 + 发 Release
git commit -am "feat: 修复客户端重复启动 [release]" \
           -m "- 修复启动时同时出现两个 fwclient 进程；- 手动停止后不再被自动拉起"
git push origin master
```

工作流 [.github/workflows/release.yml](.github/workflows/release.yml) 被触发后依次做：

1. 按 `backend/go.mod` 装 Go；把 `manifest` 的版本号补丁号 +1（`1.0.3` → `1.0.4`），
   同步 `backend/main.go` 的 `appVersion`，并用提交信息写成新的 `changelog` 条目
   （只保留最近 6 个版本，manifest 不会无限变长）；
2. `bash build.sh` 打包 → 顺序执行 `_test/verify_*.sh` → 生成 `dist/SHA256SUMS.txt`；
3. 把版本号改动自动提交回 master（提交信息带 `[skip ci]`，不会再触发一轮），
   再打 `v<新版本>` 标签；
4. 创建 Release，附 `.fpk` 与 `SHA256SUMS.txt`，说明由
   [release_notes.py](.github/scripts/release_notes.py) 从 changelog 生成
   （含安装步骤与校验方式）。同名 Release 已存在时覆盖产物并更新说明。

触发条件（即 `jobs.release.if`）：

| 事件 | 条件 | 行为 |
| --- | --- | --- |
| push | 提交信息含 `[release]` | 构建 + 验证 + 累加版本 + 回写提交 + 发 Release |
| pull_request | 标题含 `[release]` | 只构建 + 验证（合并前预检，不改版本、不发布、不打标签） |
| 手动触发 | Actions 页面 Run workflow | 同 push；勾 `dry_run` 则只构建验证 |

- **版本号是累加的**：CI 只改 `X.Y.Z` 的最后一位。要发 `1.1.0` 这类版本，
  先把 `manifest` 的 version 手改成 `1.1.0`，之后 CI 从 `1.1.1` 继续；
- 版本号只存在于两处（`manifest` 与 `backend/main.go` 的 `appVersion`），
  [bump_version.py](.github/scripts/bump_version.py) 会一起改，缺一处就报错退出；
- 只有带 `[release]` 的提交才会跑工作流，普通提交不消耗 CI 时间；
- 回写提交由内置 `GITHUB_TOKEN` 推送，按 GitHub 规则不会再触发新的工作流；
- 仓库需要写权限：Settings → Actions → General → Workflow permissions 选
  “Read and write permissions”，否则创建 Release 会 403；
- 发布后 CI 会往 master 回写一个版本号提交，本地先 `git pull` 再继续开发；
- 产物只挂在 Release 上（`dist/` 已加进 `.gitignore`），不再往仓库里塞 5MB 的包。
