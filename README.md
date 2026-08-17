# Mac mini M4 Whisper Server

本项目在 Apple Silicon Mac mini 上构建并运行 `whisper.cpp`，向可信局域网内的 OpenWhispr 提供兼容的转写接口。安装、校验、启停和跨机器验收都由可重复执行的脚本完成。

目录布局、运行状态检查和手动启动说明见：[server-info.md](./docs/server-info.md)。
命令、参数、HTTP API、调优和兼容性说明见：
[whisper-cpp-server-guide.md](./docs/whisper-cpp-server-guide.md)。

## 项目布局

```text
.
├── install.sh                 # 一键安装入口
├── scripts/                   # 服务端安装、构建和管理脚本
├── client/                    # LAN 客户端验收脚本
├── docs/                      # 运维、API 和后续方案文档
├── .env.example               # 可提交的默认配置
├── .env                       # 可选的本地覆盖，不进入 Git
├── third_party/whisper.cpp/   # 下载的上游源码，不进入 Git
├── build/whisper.cpp/         # 编译产物，不进入 Git
├── models/                    # 模型与断点文件，不进入 Git
└── var/{log,run,state}/       # 日志、PID 和状态，不进入 Git
```

脚本根据自身位置确定项目根，因此仓库移动或克隆到不同目录后无需改绝对路径。默认配置直接读取 `.env.example`；需要自定义时执行：

```bash
cp .env.example .env
```

只修改 `.env`。它已被 `.gitignore` 排除。

LAN 客户端使用的主机名或 IP 由 `WHISPER_LAN_HOST` 配置。默认值在运行时从当前 macOS
主机名动态读取；如果局域网 DNS/Bonjour 不提供该名称，请在 `.env` 中改成服务端的 LAN IP。

## 最终产物

- 项目根：仓库所在目录
- 源码：`third_party/whisper.cpp`
- 固定版本：`v1.9.2` / commit `306c88f4d1286aec1bf96e544632897886af5501`
- 构建：原生 `arm64`、Release、Metal ON
- 模型：`ggml-large-v3-turbo.bin`
- 模型 SHA-256：`1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`
- 监听：`0.0.0.0:8080`
- 健康检查：`GET /health`
- 转写接口：`POST /v1/audio/transcriptions`
- 音频转换：server 端启用 `--convert`，依赖 FFmpeg
- 语言：启动默认 `auto`

安装根目录、端口、线程数等均可在 `.env` 中调整。

## 快速开始

先准备一段真实中文录音和一段真实英文录音。然后：

```bash
cd "$(git rev-parse --show-toplevel)"
chmod +x install.sh scripts/*.sh client/*.sh
./install.sh \
  --audio /path/to/chinese.m4a \
  --audio /path/to/english.m4a \
  --start
```

如果目标机尚未安装 Homebrew，第一次增加：

```bash
./install.sh --install-homebrew \
  --audio /path/to/chinese.m4a \
  --audio /path/to/english.m4a \
  --start
```

模型约 1.5 GiB，下载和 SHA-256 校验都需要时间。脚本可重复运行；模型下载使用 `.part` 文件断点续传。

## 详细流程与原文 1–5 步对应关系

### 1. 准备系统

先人工检查 macOS 更新：

```bash
softwareupdate --list
```

系统更新可能重启，因此 `install.sh` 不会自动安装系统更新。Xcode Command Line Tools 缺失时，依赖脚本会调用 `xcode-select --install` 并要求安装完成后重跑。

依赖安装：

```bash
./scripts/01-install-dependencies.sh
# Homebrew 缺失时，审阅后改为：
./scripts/01-install-dependencies.sh --install-homebrew
```

它使用 Apple Silicon Homebrew `/opt/homebrew/bin/brew` 安装 Git、CMake 和 FFmpeg。预检会拒绝非 macOS、非 `arm64`、Rosetta 进程、依赖缺失、磁盘不足 6 GiB和非法端口：

```bash
./scripts/00-preflight.sh
```

### 2. 获取并构建稳定版

```bash
./scripts/02-build-whisper.sh
```

脚本克隆官方仓库的 `v1.9.2`，并再次核对完整 commit。构建参数为：

```text
CMAKE_BUILD_TYPE=Release
GGML_METAL=ON
WHISPER_BUILD_EXAMPLES=ON
WHISPER_BUILD_SERVER=ON
WHISPER_BUILD_TESTS=OFF
```

若专用安装目录中的源码有未提交修改，脚本会停止，不会覆盖。构建记录保存在安装根目录的 `var/state/build.txt`。

### 3. 下载并验证模型，再做 CLI 转写

```bash
./scripts/03-download-model.sh
./scripts/04-validate-cli.sh /path/to/chinese.m4a /path/to/english.m4a
```

下载脚本同时校验官方模型文件的字节数和 SHA-256。若已有正式模型校验失败，脚本会保留文件并退出，不会静默覆盖。

CLI 验证脚本先用 FFmpeg 把任意常见音频转成 16 kHz、单声道、16-bit WAV，再以 `--language auto` 调用 `whisper-cli`。转写和运行日志保存在：

```text
<项目根>/var/log/cli-validation/
```

不传音频时会使用 whisper.cpp 自带的英文 JFK 样本，只能证明构建、模型、FFmpeg 与推理链路可用，不能替代真实中英文验收。

### 4. 启动 LAN server

后台启动并等待模型加载完成：

```bash
./scripts/05-server.sh start
```

实际命令等价于：

```bash
whisper-server \
  --host 0.0.0.0 \
  --port 8080 \
  --public /absolute/path/third_party/whisper.cpp/examples/server/public \
  --inference-path /v1/audio/transcriptions \
  --convert \
  --language auto \
  --threads 4 \
  --model /absolute/path/ggml-large-v3-turbo.bin
```

管理命令：

```bash
./scripts/05-server.sh status
./scripts/05-server.sh logs
./scripts/05-server.sh stop
./scripts/05-server.sh foreground
```

PID 和日志默认位于：

```text
<项目根>/var/run/whisper-server.pid
<项目根>/var/log/whisper-server.log
```

后台模式用于完成第 4–5 步验收，不等同于开机自启。`launchd` 是原调研文档第 7 步，本安装包没有越界实现。

若 macOS Application Firewall 已启用且 LAN 客户端被阻止，先只读检查：

```bash
./scripts/06-firewall.sh
```

确认确实被防火墙阻断后再运行 `./scripts/06-firewall.sh --apply`，把精确的 server 二进制加入允许列表。脚本只会在 `WHISPER_FIREWALL_HELPER` 指向的既有最小权限 helper 精确匹配当前 server 路径时使用它；否则会显示用途并请求交互式管理员授权。

### 5. 从另一台电脑验证

复制 `client/verify-server.sh` 到同一局域网的另一台电脑：

```bash
chmod +x verify-server.sh
./verify-server.sh "http://${WHISPER_LAN_HOST}:8080" /path/to/audio.m4a
```

在客户端执行上面的命令前，将 `WHISPER_LAN_HOST` 设置为服务端的 mDNS 主机名或 LAN IP；
它不应写成仓库中的固定值。

脚本严格检查 HTTP 状态、health JSON，以及转写 JSON 中的非空 `text`。发送的 multipart 包含：

```text
file=@audio.m4a
model=whisper-1
response_format=json
```

`model=whisper-1` 是客户端兼容占位字段；该 server 不会根据它动态切换模型，真正模型由 server 启动参数固定。

## sudo 边界

正常情况下：

- 构建、模型下载、CLI 验证、server 启停：不使用 sudo；
- Xcode Command Line Tools：由 macOS 图形安装器处理；
- Homebrew 首次安装：官方安装器可能请求一次管理员授权；
- 安装 Homebrew 包：正常 Homebrew 权限下不使用 sudo；
- 系统更新：可能需要管理员授权且可能重启，必须单独确认；
- 防火墙允许项：只有匹配当前路径的最小权限 helper 才会免密执行，否则可能要求一次管理员授权。

目标机的既有 helper 仍指向整理前的旧目录，因此当前目录默认不会使用它。若要更新 helper，应单独审计并只允许当前 server 的精确路径；不要添加 `NOPASSWD: ALL`。直接操作防火墙时对应的精确命令是：

```text
/usr/libexec/ApplicationFirewall/socketfilterfw --add <精确 server 路径>
/usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp <精确 server 路径>
```

Homebrew 首次安装会执行多项系统目录准备操作，不适合猜测性地放宽 sudo 白名单；建议那一步人工输入一次管理员密码。

## 安全限制

- 只在可信家庭或小团队 LAN 使用。
- 不做路由器端口转发，不直接暴露到互联网。
- 原始 server 没有 API key、TLS 或用户隔离。
- `--convert` 会处理上传文件并调用 FFmpeg，保持 FFmpeg 和 whisper.cpp 更新。
- server 必须以普通用户运行。
- 本安装固定到 `v1.9.2` 以保证可复现；安全更新应先在另一个目录测试，再有意识地修改 tag、commit 和模型校验值。

## 故障定位

- `当前 shell 不是 arm64`：退出 Rosetta 终端，使用原生 Terminal/iTerm 重新执行。
- `port 8080 already in use`：运行 `lsof -nP -iTCP:8080 -sTCP:LISTEN`，确认占用者；不要盲目 kill。
- OpenWhispr 报 `404 File Not Found (/audio/transcriptions)`：其“服务器 URL”应填写 `http://${WHISPER_LAN_HOST}:8080/v1`，不能省略 `/v1`。客户端会自行追加 `/audio/transcriptions`。
- `/health` 本机成功、远程失败：检查 Mac IP、同一子网、访客网络隔离和 Application Firewall。
- `/health` 返回 503：模型仍在加载，查看 `./scripts/05-server.sh logs`。
- FFmpeg 转换失败：先单独运行 `ffmpeg -i <file>`，确认输入文件未损坏且格式受支持。
- 模型 checksum 失败：保留错误文件，报告实际大小和 SHA-256；不要绕过校验。
- 远程返回 JSON 但无 `text`：保存完整响应和 server 日志，确认请求路径和 `response_format=json`。

## 交接入口和上游依据

另一个对话应从 [execution-handoff.md](./docs/execution-handoff.md) 开始，并在每个验收点保留证据。

上游依据：

- [whisper.cpp 官方仓库](https://github.com/ggml-org/whisper.cpp)
- [v1.9.2 server README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/README.md)
- [v1.9.2 server 实现](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/server.cpp)
- [官方 ggml 模型仓库](https://huggingface.co/ggerganov/whisper.cpp)
- [Homebrew 官方安装说明](https://brew.sh/)
