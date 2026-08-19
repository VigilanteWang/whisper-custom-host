# Mac mini Whisper Server

本项目在 Apple Silicon Mac mini 上构建并运行固定版本的 `whisper.cpp`，向可信局域网内的 OpenWhispr 提供兼容 OpenAI 风格的语音转写接口。仓库包含安装、构建、模型校验、服务启停、局域网验收，以及控制端 SSH/Wake-on-LAN（WOL）前置配置脚本。

## 关键组件

| 组件 | 作用 | 入口 |
|---|---|---|
| `whisper-server` | 加载模型并提供 HTTP 转写服务 | `build/whisper.cpp/bin/whisper-server` |
| `whisper-cli` | 本机音频转写和冒烟测试 | `build/whisper.cpp/bin/whisper-cli` |
| SSH/WOL 设置脚本 | 在控制端生成 SSH 配置片段和 WOL 代理 | `scripts/00-setup-ssh-wol.sh` |
| 系统依赖脚本 | 检查/安装 Homebrew、Git、CMake、FFmpeg | `scripts/01-install-dependencies.sh` |
| 预检脚本 | 检查 macOS、arm64、工具链、磁盘和端口 | `scripts/00-preflight.sh` |
| 构建脚本 | 拉取固定 `whisper.cpp` commit 并启用 Metal | `scripts/02-build-whisper.sh` |
| 模型脚本 | 下载并校验 `large-v3-turbo` | `scripts/03-download-model.sh` |
| CLI 验证脚本 | FFmpeg 转 WAV 后执行本机转写 | `scripts/04-validate-cli.sh` |
| 服务管理脚本 | `start/status/logs/stop/foreground` | `scripts/05-server.sh` |
| 防火墙脚本 | 检查或放行精确的 server 二进制 | `scripts/06-firewall.sh` |
| LAN 客户端脚本 | 验证 `/health` 和 multipart 转写 | `client/verify-server.sh` |
| API/参数指南 | 详细说明 whisper.cpp、HTTP API 和故障排查 | `docs/whisper-cpp-server-guide.md` |

## 文件夹结构

```text
.
├── install.sh                       # 一键执行依赖、预检、构建、模型和 CLI 验证
├── scripts/
│   ├── 00-setup-ssh-wol.sh          # 控制端 SSH/WOL 本地配置
│   ├── 00-preflight.sh              # Mac mini 系统预检
│   ├── 01-install-dependencies.sh  # Homebrew/Git/CMake/FFmpeg
│   ├── 02-build-whisper.sh          # 固定版本构建
│   ├── 03-download-model.sh         # 模型下载和校验
│   ├── 04-validate-cli.sh           # 本机 CLI 验收
│   ├── 05-server.sh                 # server 生命周期管理
│   ├── 06-firewall.sh               # Application Firewall
│   └── lib/common.sh                # 配置、路径和公共函数
├── client/verify-server.sh          # 另一台 LAN 电脑的验收脚本
├── docs/whisper-cpp-server-guide.md # API 和详细运行指南
├── docs/whisper-server-on-demand-plan.md # 尚未实施的按需方案
├── .env.example                     # 可提交的配置模板
├── .env                              # 当前机器本地配置，不进入 Git
├── third_party/whisper.cpp/         # 下载的上游源码，不进入 Git
├── build/whisper.cpp/               # 编译产物，不进入 Git
├── models/                           # 模型及断点文件，不进入 Git
└── var/{log,run,state}/             # 日志、PID、构建/模型状态，不进入 Git
```

`third_party/`、`build/`、`models/` 和 `var/` 都由 `.gitignore` 排除；模型、日志、PID 和编译产物不会提交到 GitHub。仓库脚本根据自身位置推导项目根，移动仓库后不需要修改代码中的用户目录。

## 配置

首次部署时复制模板：

```bash
cd "$(git rev-parse --show-toplevel)"
cp .env.example .env
source .env
```

`.env` 是本机配置，不要提交。服务端常用参数包括：

```bash
WHISPER_HOST="0.0.0.0"
WHISPER_PORT="8080"
WHISPER_INFERENCE_PATH="/v1/audio/transcriptions"
WHISPER_LANGUAGE="auto"
WHISPER_THREADS="4"
WHISPER_LAN_HOST="<Mac-mini-mDNS-name-or-LAN-IP>"
```

SSH/WOL 还需要由部署者填写目标网卡的 `WHISPER_WOL_BROADCAST` 和 `WHISPER_WOL_MAC`。模板不会包含真实用户名、主机名、MAC、IP、密钥或设备指纹。

## 0. SSH 和 Wake-on-LAN 前置设置

这一步应在控制端（例如你的 MacBook）执行。WOL 只负责唤醒网卡，SSH 仍负责主机密钥校验和公钥认证；脚本不会复制私钥、修改远端文件或自动执行远端 `sudo`。

### 0.1 控制端生成本地配置

在控制端仓库的 `.env` 中填写目标 Mac mini 参数：

```bash
WHISPER_SSH_ALIAS="macmini-m4"
WHISPER_SSH_HOST="<Mac-mini-mDNS-name-or-IP>"
WHISPER_SSH_USER="<Mac-mini-login-user>"
WHISPER_SSH_PORT="22"
WHISPER_SSH_IDENTITY_FILE="${HOME}/.ssh/macmini-m4-ed25519"
WHISPER_WOL_BROADCAST="<LAN-broadcast-address>"
WHISPER_WOL_MAC="<Mac-mini-ethernet-MAC>"
```

然后运行：

```bash
./scripts/00-setup-ssh-wol.sh configure
./scripts/00-setup-ssh-wol.sh check
```

脚本会在控制端生成并设置权限：

- `~/.ssh/config.d/whisper-custom-host.conf`：SSH 别名、用户、私钥、保活和 `ProxyCommand`；
- `~/.ssh/macmini-m4-wake-proxy`：发送 WOL 魔术包、等待 TCP 22、再把字节流交给 SSH；
- `~/.ssh/config` 中的 `Include` 行（已有其它 SSH 配置不会被覆盖）。

如果私钥不存在，脚本只会提示，不会自动生成或上传：

```bash
ssh-keygen -t ed25519 -f "${WHISPER_SSH_IDENTITY_FILE}"
chmod 600 "${WHISPER_SSH_IDENTITY_FILE}"
```

### 0.2 Mac mini 上的手动设置

以下动作必须在 Mac mini 本机图形界面或已有管理员会话中完成：

1. 在“系统设置 → 通用 → 共享”开启“远程登录（Remote Login）”，只允许需要登录的用户。
2. 首次授权公钥时，确认目标主机密钥指纹后，把控制端的 `.pub` 内容追加到 Mac mini 的 `~/.ssh/authorized_keys`。不要复制私钥：

   ```bash
   cat "${WHISPER_SSH_IDENTITY_FILE}.pub" | \
     ssh -o ProxyCommand=none "${WHISPER_SSH_USER}@${WHISPER_SSH_HOST}" \
     'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
   ```

   如果首次连接尚未可用，直接在 Mac mini 本机编辑 `~/.ssh/authorized_keys`，再执行 `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`。
3. 在 Mac mini 上检查电源设置。下面的 `sudo` 只修改接电时的睡眠和网络唤醒行为，逐项审阅后再执行：

   ```bash
   sudo pmset -c sleep 0
   sudo pmset -c displaysleep 10
   sudo pmset -c womp 1
   sudo pmset -c ttyskeepawake 1
   sudo pmset -c powernap 1
   sudo pmset -c tcpkeepalive 1
   pmset -g custom
   ```

   `sleep 0` 只关闭自动空闲整机睡眠，不禁止用户从苹果菜单手动睡眠；`displaysleep 10` 只关闭显示器。
4. 可选：在 Mac mini 的 `~/.ssh/rc` 中加入一次性 UserWake 钩子，使网络 DarkWake 在首次 SSH 后提升为完整唤醒。该文件必须静默、权限为 `700`，不能向 stdout 写任何内容，否则会破坏 SFTP、VS Code 或 Codex 的 SSH 协议。

   ```sh
   #!/bin/sh
   (
       state_dir="$HOME/.ssh"
       lock_dir="$state_dir/.userwake-lock"
       state_file="$state_dir/.last-userwake-uuid"
       if ! /bin/mkdir "$lock_dir" 2>/dev/null; then exit 0; fi
       trap '/bin/rmdir "$lock_dir" 2>/dev/null' EXIT HUP INT TERM
       sleep_wake_uuid=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 -l 2>/dev/null | /usr/bin/awk -F'"' '/"SleepWakeUUID"/ { print $4; exit }')
       wake_reason=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 -l 2>/dev/null | /usr/bin/awk -F'"' '/"Wake Reason"/ { print $4; exit }')
       last_uuid=$(/bin/cat "$state_file" 2>/dev/null || true)
       case "$wake_reason" in
           *enet*|*Enet*|*MagicPacket*|*Network*)
               if [ -n "$sleep_wake_uuid" ] && [ "$sleep_wake_uuid" != "$last_uuid" ]; then
                   temp_state="$state_file.$$"
                   /usr/bin/printf '%s\n' "$sleep_wake_uuid" >"$temp_state" && /bin/mv -f "$temp_state" "$state_file"
                   /usr/bin/nohup /usr/bin/caffeinate -u -s -t 20 </dev/null >/dev/null 2>&1 &
               fi
               ;;
       esac
   ) </dev/null >/dev/null 2>&1 &
   exit 0
   ```

   保存后执行 `chmod 700 ~/.ssh/rc`。如需保持手动睡眠，先关闭会自动重连的 VS Code、Codex 或其它 SSH 客户端；否则自动重连会再次发送 WOL。

### 0.3 验收 SSH/WOL

```bash
ssh -G "${WHISPER_SSH_ALIAS}" | egrep '^(hostname|user|port|identityfile|proxycommand|connecttimeout|serveralive)'
ssh "${WHISPER_SSH_ALIAS}"
```

首次连接时确认主机密钥指纹。连接失败时检查 `dns-sd -G v4 "${WHISPER_SSH_HOST}"`、`nc -vz -w 3 "${WHISPER_SSH_HOST}" 22`、WOL 广播地址和目标 MAC；不要为了绕过主机密钥警告而删除 `known_hosts`。

## 1. 手动安装和验证流程

### 1.1 系统与依赖

系统更新只做检查，是否安装由用户决定：

```bash
softwareupdate --list
./scripts/01-install-dependencies.sh
```

Homebrew 缺失时，先审阅官方安装器，再显式运行：

```bash
./scripts/01-install-dependencies.sh --install-homebrew
```

Xcode Command Line Tools 缺失时，脚本会调用 `xcode-select --install` 并要求完成图形安装后重跑。

### 1.2 预检、构建和模型

```bash
./scripts/00-preflight.sh
./scripts/02-build-whisper.sh
./scripts/03-download-model.sh
```

构建脚本会固定 tag 和完整 commit，启用 Release、Metal、CLI 和 server。模型脚本会校验文件大小和 SHA-256；校验失败时保留文件，不会静默覆盖。

### 1.3 本机 CLI 和 server

有真实中文、英文音频时执行：

```bash
./scripts/04-validate-cli.sh /path/to/chinese.m4a /path/to/english.m4a
```

不传音频时会使用上游 JFK 样本，仅代表冒烟测试，不代表中英文验收完成。启动服务：

```bash
./scripts/05-server.sh start
./scripts/05-server.sh status
./scripts/05-server.sh logs
./scripts/05-server.sh stop
./scripts/05-server.sh foreground
```

后台服务的 PID、日志和状态分别位于 `var/run/`、`var/log/` 和 `var/state/`。当前方案没有配置 `launchd`，重启 Mac 后需要手动启动。

### 1.4 防火墙和 LAN 验收

先只读检查 Application Firewall：

```bash
./scripts/06-firewall.sh
```

只有本机 `/health` 正常而 LAN 客户端被防火墙阻止时，才执行：

```bash
./scripts/06-firewall.sh --apply
```

脚本只会在 `WHISPER_FIREWALL_HELPER` 精确匹配当前 server 路径时使用免密 helper，否则执行两条精确的防火墙命令并可能要求管理员密码。不要添加 `NOPASSWD: ALL`。

从另一台 LAN 电脑复制 `client/verify-server.sh` 并运行：

```bash
./verify-server.sh "http://${WHISPER_LAN_HOST}:8080" /path/to/test-audio.m4a
```

验收标准：`GET /health` 返回 HTTP 200 且 `{"status":"ok"}`；转写返回 HTTP 200、合法 JSON 和非空 `text`。multipart 中的 `model=whisper-1` 只是兼容占位值，服务端模型由启动参数固定。

## 服务接口和 OpenWhispr

默认监听 `0.0.0.0:8080`，接口为：

```text
GET  http://127.0.0.1:8080/health
POST http://${WHISPER_LAN_HOST}:8080/v1/audio/transcriptions
```

OpenWhispr 的 Base URL 填：

```text
http://${WHISPER_LAN_HOST}:8080/v1
```

客户端会追加 `/audio/transcriptions`，不能省略 `/v1`。`--convert` 会让 FFmpeg 处理上传文件，因此服务只应暴露在可信 LAN，不要配置公网端口转发。

详细 CLI、HTTP 字段、响应格式和兼容性说明见 [whisper-cpp-server-guide.md](./docs/whisper-cpp-server-guide.md)。