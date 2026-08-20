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
| 唯一权威模型 | `~/Library/Application Support/whisper-custom-host/runtime/models/ggml-large-v3-turbo.bin`，约 1.5 GiB |
| LAN 网关 | `0.0.0.0:8080` |
| 模型后端 | `127.0.0.1:18080` |
| 默认空闲回收 | 300 秒 |
| 外部转写路径 | `POST /v1/audio/transcriptions` |

模型下载脚本会同时校验文件大小和 SHA-256；不要用未验收的模型替换固定文件。
`scripts/03-download-model.sh` 是模型位置的唯一管理入口：它在上述 Application Support 路径下载、
校验或迁移模型，并把 `model.txt` 写在同一个 `runtime/models/` 目录。`scripts/04-validate-cli.sh`、
`scripts/05-server.sh` 和 `scripts/08-on-demand-service.sh` 全部使用这一份模型。

仓库 `models/` 不再存放正式模型。若升级前仍存在
`<项目根>/models/ggml-large-v3-turbo.bin`，03 脚本会分别对旧文件和新权威文件执行固定 size+SHA
校验；只有两份都匹配后才删除旧文件。任一校验失败都会保留旧文件并停止迁移。

## Issue #2 实现状态

按需网关的重构已经落地并完成当前机器上的运行验收：

- 原来的单文件网关已拆为 `main`、`config`、`support`、`platform_process`、
  `backend_controller` 和 `http_gateway` 六个职责明确的模块；
- 当前用户的 LaunchAgent 已验证可用；真实音频的冷请求、热请求、300 秒空闲回收和再次唤醒均已验证；
- 本轮真实 JFK 已分别通过 CLI、direct HTTP 和 on-demand HTTP 三条路径；最终 on-demand 请求返回
  HTTP 200，耗时 6.82 秒；
- Application Firewall 只读检查显示防火墙已启用，但新的 Application Support 精确网关二进制没有
  匹配的 allow 规则，仍需重新 apply 并完成跨机器验证；
- T17（另一台机器的跨 LAN 验证）、注销/登录边界，以及 direct 模式正式回滚演练仍未完成。

本轮不在文档中固化运行时 PID；请用服务状态和日志命令读取现场值。

## 项目内容

| 路径 | 作用 |
|---|---|
| `install.sh` | 按顺序执行依赖、预检、构建、模型下载、CLI 验证和按需服务安装 |
| `scripts/00-setup-ssh-wol.sh` | 可选的控制端 SSH/Wake-on-LAN 配置 |
| `scripts/00-preflight.sh` | 检查 macOS、arm64、工具链、磁盘和端口 |
| `scripts/01-install-dependencies.sh` | 检查或安装 Homebrew、Git、CMake、FFmpeg 等依赖 |
| `scripts/02-build-whisper.sh` | 固定 commit 构建 `whisper-cli` 和 `whisper-server`，启用 Metal |
| `scripts/03-download-model.sh` | 在唯一权威路径下载/校验模型，并安全迁移仓库旧模型 |
| `scripts/04-validate-cli.sh` | 使用唯一权威模型做 CLI 本机音频冒烟验证 |
| `scripts/06-firewall.sh` | 检查或放行 Application Support 中实际监听 LAN 的精确网关二进制 |
| `scripts/07-build-on-demand-gateway.sh` | 核对 pinned commit/header，构建并全量验证 C++17 网关后原子发布 |
| `scripts/08-on-demand-service.sh` | 原子部署最小运行时，管理当前用户 LaunchAgent、状态和日志 |
| `gateway/main.cpp` | 进程入口、参数解析和启动错误处理 |
| `gateway/config.h`, `gateway/config.cpp` | 配置、CLI > 环境变量 > 默认值优先级和路径重派生 |
| `gateway/support.h`, `gateway/support.cpp` | HTTP/JSON、临时文件、bounded queue、deadline 等通用支持 |
| `gateway/platform_process.h`, `gateway/platform_process.cpp` | macOS spawn、PID/命令行身份校验、信号和子进程回收 |
| `gateway/backend_controller.h`, `gateway/backend_controller.cpp` | 后端状态机、RequestLease RAII、空闲回收和重启 |
| `gateway/http_gateway.h`, `gateway/http_gateway.cpp` | 路由、流式上传暂存和后端转发 |
| `gateway/CMakeLists.txt` | `gateway_core` 静态库、最终网关 target、CTest 和 sanitizer 配置 |
| `launchd/com.local.whisper-on-demand-gateway.plist.in` | LaunchAgent 模板 |
| `client/verify-server.sh` | 从另一台 LAN 电脑执行端到端验收 |
| `tests/on-demand-integration.sh` | 使用 mock 后端在临时 loopback 端口覆盖 15 个生命周期/HTTP 场景 |
| `docs/whisper-server-on-demand-plan.md` | 按需设计、边界和验收记录 |
| `docs/whisper-cpp-server-guide.md` | 原生 whisper.cpp、CLI 和 whisper-server 参考说明 |

仓库内生成的源码、构建产物和 direct 模式状态分别位于 `third_party/`、`build/` 和 `var/`，均不应
提交到 Git。仓库 `models/` 只视为旧版迁移来源，不再是正式模型目录。

仓库中的审计构建产物仍位于 `build/on-demand/`；LaunchAgent 不直接从 `~/Documents` 下执行它，
而是从验证过的 build/state 把最小可执行运行文件原子部署到
`~/Library/Application Support/whisper-custom-host/`，与 03 脚本直接管理在该处的唯一权威模型配合。
这样既保留可审计构建，也避开后台进程访问 Documents 时的 macOS TCC 阻塞。

### 网关构建与验证

构建脚本先确认 whisper.cpp 固定 commit，以及 `examples/server/httplib.h` 在该 commit 中的原始
Git blob；原始 header 不会被修改。CMake 读取这个 pinned header，在构建目录生成 raw-reader
compatibility header，供 multipart 原样转发使用。

脚本在发布前建立隔离的 release 候选目录，并依次执行：

1. CMake release 构建、CTest 和 `--help` 检查；
2. 15 个临时 loopback 集成场景（包括定长上传早启动、chunked 超限不启动、raw multipart 保真、空闲回收和故障退避）；
3. ASan/UBSan 构建，并再次运行 CTest 和同一组 loopback 集成场景。

只有上述检查全部成功，才把候选二进制和构建状态记录通过临时文件 `rename` 原子发布到
`build/on-demand/bin/`；检查失败不会覆盖当前可用产物。

`scripts/08-on-demand-service.sh start` 会再次核对 `build/on-demand/gateway-build.txt` 中的二进制和
header SHA，并原地校验 03 脚本管理的唯一权威模型；随后把 gateway、`whisper-server`、所需 dylib、
pinned header、commit attestation、run 和 log 目录部署到 Application Support。08 不复制或维护第二份
模型。部署时会把 server/dylib 的 checkout rpath 改为
`@executable_path`/`@loader_path`，并对 gateway、server 和 dylib 重新做 ad-hoc 签名。若已有受管
服务，只有 health 同时满足 `backend=cold` 且 active/pending 都为 0 时才允许 bootout 后重启；否则
拒绝中断在线请求。

配置解析遵循 CLI > 环境变量 > 默认值；最终 `root/source` 确定后才重派生 server、model、public、
header、PID 和日志路径，避免改了根目录却继续使用旧路径。每个请求由 `RequestLease` RAII 对象
登记并在所有返回路径释放 active 计数。带合法 `Content-Length` 的请求会在上传完成前启动后端以重叠模型加载；
chunked 请求必须先完整暂存并确认没有超过限制，超限返回 413 且绝不启动后端。

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
4. 在 Application Support 唯一权威路径下载/校验 `large-v3-turbo`，或安全迁移仓库旧模型；
5. 用同一模型运行本机 CLI 验证；
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

仓库中的已验证构建文件：

```text
build/on-demand/bin/whisper-on-demand-gateway
build/on-demand/gateway-build.txt
```

LaunchAgent 的最小运行时位于：

```text
~/Library/Application Support/whisper-custom-host/
├── bin/                                 # gateway、whisper-server、所需 dylib
└── runtime/
    ├── models/ggml-large-v3-turbo.bin
    ├── models/model.txt                   # 与模型同目录的校验状态
    ├── whisper.cpp/examples/server/httplib.h
    ├── whisper.cpp/.git/HEAD             # pinned commit attestation
    ├── run/                              # gateway/backend PID、uploads
    └── log/                              # gateway/backend 业务日志
```

LaunchAgent 的标准输出和错误日志位于：

```text
~/Library/Logs/whisper-custom-host/whisper-on-demand-gateway.stdout.log
~/Library/Logs/whisper-custom-host/whisper-on-demand-gateway.stderr.log
```

`stop` 保留 LaunchAgent 文件；`uninstall` 只停止服务并删除本工具生成的 plist，不删除模型、
源码或构建产物。LaunchAgent 的安装、启动和当前登录会话内的服务状态已经验证；它仍属于当前登录用户，
注销/登录边界尚未完成验收，不能把它当作无人登录时的系统级服务。

LaunchAgent 的 `WorkingDirectory` 也是
`~/Library/Application Support/whisper-custom-host/`。所有 ProgramArguments 使用上述运行时绝对路径，
避免 launchd/xpcproxy 在 `~/Documents` 下执行或解析工作目录时触发 TCC 阻塞。

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

真实音频的冷/热请求、300 秒空闲回收和再次唤醒已在服务端验证；最终真实 JFK 音频请求返回 HTTP 200，
耗时 6.84 秒。这不能替代 T17 的另一台机器跨 LAN 验收。音频文件应使用实际业务语言和格式。

## 防火墙、SSH 和 Wake-on-LAN

当前只读检查显示 Application Firewall 已启用，但
`~/Library/Application Support/whisper-custom-host/bin/whisper-on-demand-gateway` 没有匹配的 allow 规则。
运行时路径从仓库迁移到 Application Support 后，旧 checkout 二进制的规则不再等价；需要重新应用并在
另一台 LAN 机器完成 T17：

```bash
./scripts/06-firewall.sh --target on-demand
./scripts/06-firewall.sh --target on-demand --apply
```

`--apply` 只放行按需网关的精确路径，可能要求管理员密码；不要配置 `NOPASSWD: ALL`。上传会触发
FFmpeg 处理，因此服务只适合可信 LAN，禁止路由器端口转发。

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

### direct 模式回滚

按需网关不覆盖 `whisper-server` 二进制和模型，但 direct ↔ on-demand 的正式切换/回滚演练尚未完成。
在演练完成前，不要把 `scripts/05-server.sh start` 当作已验证的无缝回滚路径；需要切换时先保留现场日志和
防火墙规则，按计划文档逐项核对端口及进程身份。

## 相关文档

- [原生 whisper.cpp 与 whisper-server 说明](docs/whisper-cpp-server-guide.md)
- [按需服务设计与验收记录](docs/whisper-server-on-demand-plan.md)
- [whisper.cpp v1.9.2 主 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/README.md)
- [whisper-server v1.9.2 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/README.md)
