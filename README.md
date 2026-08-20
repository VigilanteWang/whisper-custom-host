# whisper.cpp 按需语音转写服务

本项目在 Apple Silicon Mac mini 上部署固定版本的 `whisper.cpp`，为可信局域网内的
OpenWhispr 提供兼容 OpenAI 风格的语音转写接口。

运行时由一个轻量 HTTP 网关常驻监听 LAN 端口；收到
`POST /v1/audio/transcriptions` 后，网关才在回环地址启动 `whisper-server`，
请求完成且空闲达到阈值后自动回收模型进程。这样平时不需要让约 1.5 GiB 的模型常驻内存。

## 运行结构

```text
OpenWhispr / curl
        |
        | 可信 LAN，0.0.0.0:8080
        v
whisper-on-demand-gateway       常驻，不加载 Whisper 模型
        |
        | 回环地址，127.0.0.1:18080
        v
whisper-server                  按请求启动，空闲退出
        |
        v
ggml-large-v3-turbo.bin
```

外部客户端始终使用：

```text
http://<Mac-mini-host-or-IP>:8080/v1
```

后端端口只允许网关访问，不应暴露到 LAN。

## 固定基线

| 项目 | 值 |
|---|---|
| 操作系统 | macOS，Apple Silicon `arm64` |
| whisper.cpp | `v1.9.2` |
| 固定 commit | `306c88f4d1286aec1bf96e544632897886af5501` |
| 推理模型 | `large-v3-turbo` |
| 模型文件 | `models/ggml-large-v3-turbo.bin`，约 1.5 GiB |
| LAN 网关 | `0.0.0.0:8080` |
| 模型后端 | `127.0.0.1:18080` |
| 默认空闲回收 | 300 秒 |
| 外部转写路径 | `POST /v1/audio/transcriptions` |

模型下载脚本会同时校验文件大小和 SHA-256；不要用未验收的模型替换固定文件。

## 项目内容

| 路径 | 作用 |
|---|---|
| `install.sh` | 按顺序执行依赖、预检、构建、模型下载、CLI 验证和按需服务安装 |
| `scripts/00-setup-ssh-wol.sh` | 可选的控制端 SSH/Wake-on-LAN 配置 |
| `scripts/00-preflight.sh` | 检查 macOS、arm64、工具链、磁盘和端口 |
| `scripts/01-install-dependencies.sh` | 检查或安装 Homebrew、Git、CMake、FFmpeg 等依赖 |
| `scripts/02-build-whisper.sh` | 固定 commit 构建 `whisper-cli` 和 `whisper-server`，启用 Metal |
| `scripts/03-download-model.sh` | 下载并校验 `large-v3-turbo` |
| `scripts/04-validate-cli.sh` | 使用 CLI 做本机音频冒烟验证 |
| `scripts/06-firewall.sh` | 检查或放行按需网关这个精确二进制 |
| `scripts/07-build-on-demand-gateway.sh` | 编译 C++17 按需网关 |
| `scripts/08-on-demand-service.sh` | 管理当前用户的 LaunchAgent、状态和日志 |
| `gateway/whisper_on_demand_gateway.cpp` | 网关源码 |
| `launchd/com.local.whisper-on-demand-gateway.plist.in` | LaunchAgent 模板 |
| `client/verify-server.sh` | 从另一台 LAN 电脑执行端到端验收 |
| `tests/on-demand-integration.sh` | 使用 mock 后端测试生命周期，不加载真实模型 |
| `docs/whisper-server-on-demand-plan.md` | 按需设计、边界和验收记录 |
| `docs/whisper-cpp-server-guide.md` | 原生 whisper.cpp、CLI 和 whisper-server 参考说明 |

生成的源码、构建产物、模型和运行时文件分别位于
`third_party/`、`build/`、`models/` 和 `var/`，均不应提交到 Git。

## 配置

首次部署：

```bash
cd "$(git rev-parse --show-toplevel)"
cp .env.example .env
```

在 `.env` 中至少确认 LAN 地址；其余按需参数可以沿用模板默认值：

```bash
WHISPER_LAN_HOST="<Mac-mini-host-or-IP>"

WHISPER_GATEWAY_PORT="8080"
WHISPER_BACKEND_PORT="18080"

WHISPER_IDLE_TIMEOUT_SECONDS="300"
WHISPER_STARTUP_TIMEOUT_SECONDS="180"
WHISPER_SHUTDOWN_TIMEOUT_SECONDS="15"
WHISPER_REQUEST_TIMEOUT_SECONDS="900"
WHISPER_MAX_PENDING_REQUESTS="4"
WHISPER_MAX_UPLOAD_BYTES="268435456"
WHISPER_START_FAILURE_BACKOFF_SECONDS="10"
```

注意：

- 按需网关固定监听 `0.0.0.0`，后端固定监听 `127.0.0.1`；这两个 host 不作为 `.env` 配置项，避免误把后端暴露到 LAN。
- 网关端口和后端端口不能相同。
- `WHISPER_LAN_HOST` 是客户端访问 Mac mini 时使用的 mDNS 主机名或 LAN IP。
- `.env` 可能包含本机地址和 SSH 信息，不要提交。

## 安装和启动

前置条件是 macOS Apple Silicon、Xcode Command Line Tools、Git、CMake、FFmpeg 和 curl。
缺少 Homebrew 时可以让脚本调用官方安装器；Xcode Command Line Tools 仍需完成系统弹窗安装。

完整流程：

```bash
./install.sh --on-demand --start
```

如果还没有 Apple Silicon Homebrew：

```bash
./install.sh --install-homebrew --on-demand --start
```

如需用真实中文或英文音频做 CLI 验证，可附加一个或多个音频：

```bash
./install.sh --on-demand --start \
  --audio /path/to/chinese.m4a \
  --audio /path/to/english.m4a
```

安装脚本会依次完成：

1. 检查或安装依赖；
2. 检查主机架构、工具链、磁盘和端口；
3. 拉取并固定 `whisper.cpp v1.9.2`，启用 Metal、CLI 和 server；
4. 下载并校验 `large-v3-turbo`；
5. 运行本机 CLI 验证；
6. 编译按需网关；
7. 校验模型后安装并启动当前登录用户的 LaunchAgent。

不希望立即启动时去掉 `--start`。也可以分步执行：

```bash
./scripts/01-install-dependencies.sh
./scripts/00-preflight.sh
./scripts/02-build-whisper.sh
./scripts/03-download-model.sh
./scripts/04-validate-cli.sh /path/to/test-audio.m4a
./scripts/07-build-on-demand-gateway.sh
./scripts/08-on-demand-service.sh install
./scripts/08-on-demand-service.sh start
```

服务以普通用户运行，不要用 `sudo` 启动安装脚本、网关或 `whisper-server`。
`--install-homebrew` 以及防火墙应用可能需要系统授权。

## 服务管理

```bash
./scripts/08-on-demand-service.sh status
./scripts/08-on-demand-service.sh logs all
./scripts/08-on-demand-service.sh logs gateway
./scripts/08-on-demand-service.sh logs backend
./scripts/08-on-demand-service.sh stop
./scripts/08-on-demand-service.sh start
./scripts/08-on-demand-service.sh uninstall
```

LaunchAgent 文件为：

```text
~/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist
```

网关和后端运行文件：

```text
build/on-demand/bin/whisper-on-demand-gateway
var/run/whisper-on-demand-gateway.pid
var/run/whisper-on-demand-backend.pid
var/run/uploads/                         # 临时上传文件
var/log/whisper-on-demand-backend.log
```

LaunchAgent 的标准输出和错误日志位于：

```text
~/Library/Logs/whisper-custom-host/whisper-on-demand-gateway.stdout.log
~/Library/Logs/whisper-custom-host/whisper-on-demand-gateway.stderr.log
```

`stop` 保留 LaunchAgent 文件；`uninstall` 只停止服务并删除本工具生成的 plist，不删除模型、
源码或构建产物。LaunchAgent 属于当前登录用户，不能替代无人登录时的系统级服务。

仅需前台排障时：

```bash
./scripts/08-on-demand-service.sh foreground
```

## HTTP 接口

网关提供以下接口：

| 方法和路径 | 行为 |
|---|---|
| `GET /health` | 网关存活检查，返回后端状态，不触发模型加载 |
| `GET /ready` | 后端 ready 时返回 200；冷态或加载中返回 503 |
| `OPTIONS /v1/audio/transcriptions` | CORS 预检，不触发模型加载 |
| `POST /v1/audio/transcriptions` | 接收 multipart 音频；冷态时启动后端并等待转写 |
| 其他路径 | 返回 404；不暴露后端管理接口 |

请求必须使用 multipart，音频字段名为 `file`；`curl -F` 会自动生成正确的 boundary，
不要手工覆盖 `Content-Type`：

```bash
curl --fail --show-error \
  --form 'file=@/absolute/path/audio.m4a' \
  --form 'model=whisper-1' \
  --form 'response_format=json' \
  "http://<Mac-mini-host-or-IP>:8080/v1/audio/transcriptions"
```

返回示例：

```json
{"text":"转写结果"}
```

`model=whisper-1` 只是 OpenAI 风格客户端的兼容字段，不会改变服务端固定的
`large-v3-turbo`。

## OpenWhispr 配置

在 OpenWhispr 中填写：

```text
Base URL: http://<Mac-mini-host-or-IP>:8080/v1
Model:    whisper-1
```

客户端会在 Base URL 后追加 `/audio/transcriptions`，所以 Base URL 必须包含 `/v1`。
不要把 `/health` 或 `/ready` 当作发送转写请求的前置条件：`/health` 只表示网关存活，
真正的 `POST` 会在冷态触发后端启动。

## 局域网验收

先在服务端确认网关：

```bash
./scripts/08-on-demand-service.sh status
curl --fail "http://127.0.0.1:8080/health"
```

再从另一台 LAN 电脑复制 `client/verify-server.sh`，执行完整冷启动验收：

```bash
./client/verify-server.sh --on-demand --idle-timeout 300 \
  "http://<Mac-mini-host-or-IP>:8080" /path/to/test-audio.m4a
```

脚本会检查：

- 冷态 `/health` 为 200，且后端状态为 `cold`；
- 冷态 `/ready` 为 503；
- 首次 multipart 转写返回 200 和非空 `text`；
- 空闲超时后后端退出；
- 再次请求能启动新的后端进程。

真实 LAN 验收不能由本机 loopback 测试替代；音频文件应使用实际业务语言和格式。

## 防火墙、SSH 和 Wake-on-LAN

只在确认本机健康、但 LAN 客户端被 macOS Application Firewall 阻止时应用规则：

```bash
./scripts/06-firewall.sh --target on-demand
./scripts/06-firewall.sh --target on-demand --apply
```

`--apply` 只放行按需网关的精确路径，可能要求管理员密码；不要配置
`NOPASSWD: ALL`。上传会触发 FFmpeg 处理，因此服务只适合可信 LAN，禁止路由器端口转发。

如果需要从控制端唤醒或登录 Mac mini，可先在控制端填写 `.env` 中的 SSH/WOL 字段，然后执行：

```bash
./scripts/00-setup-ssh-wol.sh configure
./scripts/00-setup-ssh-wol.sh check
```

Mac mini 仍需手动开启 Remote Login、确认主机密钥并配置公钥认证。WOL 只负责唤醒网络主机；
LaunchAgent 仍要求目标用户会话可用，WOL 不会替代服务生命周期管理。

## 常见问题

### `/health` 不可访问

执行：

```bash
./scripts/08-on-demand-service.sh status
./scripts/08-on-demand-service.sh logs all
```

确认 LaunchAgent 已加载、网关 PID 存在且 8080 未被未知进程占用。

### `/health` 正常但 `/ready` 返回 503

冷态或模型加载期间这是正常现象。直接提交转写请求；若持续返回 503，检查后端日志、
模型文件完整性和 `whisper.cpp` commit。

### 转写返回 400 或 413

确认请求是 multipart 且文件字段名为 `file`。413 表示超过
`WHISPER_MAX_UPLOAD_BYTES`，调整配置后重新安装并启动 LaunchAgent。

### 端口被占用

服务脚本不会自动停止未知进程。先查明占用 8080 或 18080 的进程，再决定是否停止它，
然后重新运行：

```bash
./scripts/08-on-demand-service.sh start
```

## 相关文档

- [原生 whisper.cpp 与 whisper-server 说明](docs/whisper-cpp-server-guide.md)
- [按需服务设计与验收记录](docs/whisper-server-on-demand-plan.md)
- [whisper.cpp v1.9.2 主 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/README.md)
- [whisper-server v1.9.2 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/README.md)
