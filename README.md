# 基于 whisper.cpp server 的按需语音转写服务

本项目基于 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 的 `whisper-server`，额外实现了一个轻量 Gateway。
Gateway 常驻监听并提供兼容 OpenAI 风格的 `/v1/audio/transcriptions` 接口；收到转写请求后，才按需启动
`whisper-server` 并加载模型，空闲一段时间后自动退出以释放资源。服务可部署在局域网中的 macOS Apple Silicon
主机，提供给 OpenWhispr 客户端使用。

项目同时提供完整的 macOS 下载、依赖安装、`whisper.cpp` 编译、模型下载校验、Gateway 构建验证和 LaunchAgent
安装脚本，安装流程可以从源码准备一直执行到服务启动。

Gateway 的实现、架构和运行细节见 [gateway/README.md](gateway/README.md)。

## 文件夹结构

```text
.
├── install.sh                         # 一键安装入口
├── uninstall.sh                       # 完整卸载入口
├── .env.example                       # 可覆盖的本机配置模板
├── client/
│   └── verify-server.sh               # 从另一台 LAN 主机验证服务
├── docs/                              # 背景与原生 whisper.cpp 参考文档
├── gateway/                           # 按需 Gateway 源码与专属说明
├── launchd/                           # 当前用户 LaunchAgent 模板
├── scripts/
│   ├── 00-preflight.sh                # 环境、磁盘、端口预检
│   ├── 01-install-dependencies.sh     # 安装或检查依赖
│   ├── 02-build-whisper.sh            # 下载并构建固定版本 whisper.cpp server
│   ├── 03-download-model.sh           # 按 .env 配置下载并校验模型
│   ├── 04-validate-cli.sh             # CLI 冒烟验证
│   ├── 05-server.sh                   # direct whisper-server 启停
│   ├── 06-firewall.sh                 # Application Firewall 检查/精确放行
│   ├── 07-build-on-demand-gateway.sh  # 构建并验证按需 Gateway
│   └── 08-on-demand-service.sh        # 安装、启停、状态与日志
└── tests/                             # Gateway 单元与集成测试
```

构建产物在 `build/`，第三方源码在 `third_party/`，运行时临时状态在 `var/`；它们都不应提交。正式模型和已部署服务运行时位于：

```text
~/Library/Application Support/whisper-custom-host/
```

## 运行结构

```text
OpenWhispr / curl
        │  可信 LAN，http://<Mac-mini-host-or-IP>:8080/v1
        ▼
whisper-on-demand-gateway  ──  常驻，0.0.0.0:8080，不加载模型
        │  仅本机回环，127.0.0.1:18080
        ▼
whisper-server             ──  按请求启动，空闲设定的时间后退出
        │
        ▼
ggml-${WHISPER_MODEL}.bin   ──  当前配置的模型文件
```

客户端只访问 Gateway；后端端口不可暴露到 LAN。

## 模型配置

默认模型是 `large-v3-turbo`。模型可以修改：请在 [ggerganov/whisper.cpp 的 Hugging Face 文件列表](https://huggingface.co/ggerganov/whisper.cpp/tree/main)
中选择对应的 `ggml-*.bin` 文件，并在 `.env` 中修改模型名及其校验信息。例如文件名为
`ggml-large-v3-turbo-q5_0.bin` 时，模型名写成 `large-v3-turbo-q5_0`：

```bash
WHISPER_MODEL="${WHISPER_MODEL:-large-v3-turbo-q5_0}"
WHISPER_MODEL_SHA256="<该文件的 SHA-256>"
WHISPER_MODEL_SIZE_BYTES="<该文件的字节数>"
```

`scripts/03-download-model.sh` 会根据 `WHISPER_MODEL` 拼接 Hugging Face 下载地址，并在安装过程中检查文件大小和
SHA-256；因此切换模型时要同时更新这三个参数。安装脚本会使用 `.env` 中的配置下载并校验选定模型，CLI、direct
server 和按需 Gateway 共用这份模型。

## 简要安装

前置条件：macOS Apple Silicon、Xcode Command Line Tools、Git、CMake、FFmpeg 和 `curl`。首次安装前，复制并按实际 LAN 主机名或 IP 检查配置：

```bash
cp .env.example .env
```

执行完整安装、模型校验并启动按需服务：

```bash
./install.sh --on-demand --start
```

该命令会依次完成依赖检查、`whisper.cpp`/`whisper-server` 编译、选定模型下载与校验、Gateway 构建验证、
LaunchAgent 安装和服务启动。

若尚未安装 Homebrew：

```bash
./install.sh --install-homebrew --on-demand --start
```

`--install-homebrew` 和防火墙放行可能要求系统管理员授权；服务本身始终以当前普通用户运行，勿用 `sudo` 启动安装脚本、Gateway 或 `whisper-server`。

安装完成后，先在本机确认状态，再从另一台可信 LAN 主机执行端到端验证：

```bash
./scripts/08-on-demand-service.sh status
./client/verify-server.sh --on-demand --idle-timeout 300 \
  http://<Mac-mini-host-or-IP>:8080 /absolute/path/to/test-audio.m4a
```

## 日常维护

```bash
# 查看状态与日志
./scripts/08-on-demand-service.sh status
./scripts/08-on-demand-service.sh logs all

# 停止或启动当前用户的 LaunchAgent
./scripts/08-on-demand-service.sh stop
./scripts/08-on-demand-service.sh start

# 重新构建后清理 Application Support 中的旧运行时再启动
./scripts/07-build-on-demand-gateway.sh
./scripts/08-on-demand-service.sh start --purge

# 仅卸载本工具创建的 LaunchAgent；加 --purge 时仍保留模型
./scripts/08-on-demand-service.sh uninstall
./scripts/08-on-demand-service.sh uninstall --purge

# 只读检查防火墙；确需放行时才加 --apply
./scripts/06-firewall.sh --target on-demand
./scripts/06-firewall.sh --target on-demand --apply
```

安装入口也可在完成 07 构建后清理旧运行时，再部署或启动：

```bash
./install.sh --on-demand --purge --start
```

`--purge` 只清理 Application Support 中除模型外的产物；完整卸载前先预览，再确认执行：

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

完整卸载会删除模型、LaunchAgent、Application Support、项目日志、精确防火墙规则以及仓库内的 `build/`、`var/` 和已验证干净的 `third_party/whisper.cpp/`。它保留 Git 跟踪文件、`.env`、仓库 `models/`、其他无关未跟踪文件、Homebrew/共享依赖及 SSH/WOL 和手工系统设置。不要使用 `sudo ./uninstall.sh`。

LaunchAgent 标准输出与错误日志在：

```text
~/Library/Logs/whisper-custom-host/
```
