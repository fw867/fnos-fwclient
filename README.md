# 内网穿透（fwclient）· 飞牛 fnOS 应用

把 fw867 的 `fwclient` 内网穿透客户端封装成飞牛 fnOS 原生应用：装好后在**应用设置**里填写
网关域名和访问令牌，桌面打开「内网穿透」即可看运行状态、实时日志、当前版本，并一键升级客户端。

- 应用包名：`fwclient`
- 显示名称：内网穿透
- 版本：`1.0.2`
- 架构：x86_64（`platform=x86`）
- 管理页面端口：`18443`

---

## 1. 功能

| 功能 | 说明 |
| --- | --- |
| 网关域名 / 令牌配置 | 安装向导、应用设置向导、网页管理页三处均可修改，令牌留空表示不修改 |
| 客户端启停 | 启动、规范关闭（`fwclient -k`）、重启；异常退出自动重连 |
| 实时日志 | 读取 `fwclient` 日志尾部，支持 100/300/1000/3000 行、4 秒自动刷新、清空 |
| 版本查询 | 调用 `fwclient -v`，直接显示客户端自报的版本号 |
| 一键升级 | 调用 `fwclient -u`，实时回显升级过程输出，升级后自动刷新版本 |
| 设备标识保留 | 升级、卸载（默认）均保留 `fwclient.id`，避免服务端把设备当成新机器 |
| 开机自启 | 应用启动时按配置自动连接；可在管理页关闭 |

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
│   ├── cmd/                      # 生命周期脚本
│   │   ├── lib.sh                # 公共函数（路径、配置、进程控制、程序定位）
│   │   ├── main                  # start / stop / status
│   │   ├── install_init|_callback
│   │   ├── upgrade_init|_callback
│   │   ├── config_init|_callback
│   │   └── uninstall_init|_callback
│   ├── config/                   # privilege / resource
│   └── wizard/                   # install / config / upgrade / uninstall 向导
├── backend/                      # 管理后端源码（Go，仅标准库）
│   ├── main.go
│   ├── proc_unix.go / proc_windows.go
│   └── ui/                       # 内嵌到二进制的管理页面
├── dist/fwclient-1.0.2.fpk       # 打包产物（可直接安装）
├── build.sh                      # 一键构建
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
- 客户端的所有文件（pid / 日志 / 设备标识）统一放在 `TRIM_PKGVAR/run`，
  通过 `-dir` 一次性指定，卸载/迁移都不会散落到系统目录。

### HTTP 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/status` | 运行状态、PID、版本、设备标识、配置摘要 |
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
校验包结构 → 调用 fnpack 打包 → 用 `repack_fpk.py` 补回可执行位。

> fnpack 打包时会把文件权限统一写成 `0666`，而 fnOS 直接执行 `cmd/` 下的脚本，
> 所以打包后必须用 `repack_fpk.py` 重打包：`cmd/*` 设 `0755`，
> `app/bin/fwclient`、`app/server/fwclient-server` 设 `0755`。

手动分步：

```bash
cd backend
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
    -o ../fwclient-app/app/server/fwclient-server .
cd ..
python repack_fpk.py dist/fwclient-1.0.2.fpk
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
```

已在 WSL Ubuntu 中验证结果（合计 73 项全过）：

```
verify_linux      PASS=17 FAIL=0
verify_lifecycle  PASS=10 FAIL=0
verify_restart    PASS=11 FAIL=0
verify_uninstall  PASS=7  FAIL=0
verify_fixes      PASS=28 FAIL=0
```

> 说明：以上验证在 WSL 下以当前用户身份运行，未覆盖 fnOS 的
> `run-as=package` 用户切换、应用中心安装界面等系统侧行为，请在真机上再走一遍安装流程。

## 7. 已知行为与注意事项

- **首次连接**：安装后如未填配置，应用仍会启动管理页，填好网关域名与令牌保存即自动连接。
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
