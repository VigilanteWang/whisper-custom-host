# whisper.cpp 按需语音转写服务

面向可信局域网的 macOS Apple Silicon 语音转写服务，供 OpenWhispr 使用兼容 OpenAI 风格的
`/v1/audio/transcriptions` 接口。服务采用固定版本的 `whisper.cpp` 与 `large-v3-turbo` 模型；模型只在有转写请求时运行，空闲后自动释放。

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
│   ├── 02-build-whisper.sh            # 构建固定版本 whisper.cpp
│   ├── 03-download-model.sh           # 下载并校验唯一模型文件
│   ├── 04-validate-cli.sh             # CLI 冒烟验证
│   ├── 06-firewall.sh                 # Application Firewall 检查/精确放行
│   ├── 07-build-on-demand-gateway.sh  # 构建并验证 Gateway
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
whisper-server             ──  按请求启动，空闲 300 秒后退出
        │
        ▼
ggml-large-v3-turbo.bin    ──  唯一权威模型文件
```

客户端只访问 Gateway；后端端口不可暴露到 LAN。

## 简要安装

前置条件：macOS Apple Silicon、Xcode Command Line Tools、Git、CMake、FFmpeg 和 `curl`。首次安装前，复制并按实际 LAN 主机名或 IP 检查配置：

```bash
cp .env.example .env
```

执行完整安装、模型校验并启动按需服务：

```bash
./install.sh --on-demand --start
```

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

# 重新构建并验证 Gateway，随后重新部署服务
./scripts/07-build-on-demand-gateway.sh
./scripts/08-on-demand-service.sh start

# 重新构建后清理 Application Support 中的旧运行时，保留模型再启动
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

`--purge` 只清理 Application Support 中除权威模型外的产物；完整卸载前先预览，再确认执行：

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

完整卸载会删除权威模型、LaunchAgent、Application Support、项目日志、精确防火墙规则以及仓库内的 `build/`、`var/` 和已验证干净的 `third_party/whisper.cpp/`。它保留 Git 跟踪文件、`.env`、仓库 `models/`、其他无关未跟踪文件、Homebrew/共享依赖及 SSH/WOL 和手工系统设置。不要使用 `sudo ./uninstall.sh`。

LaunchAgent 标准输出与错误日志在：

```text
~/Library/Logs/whisper-custom-host/
```
