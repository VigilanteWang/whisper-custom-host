# 给另一个对话的执行说明

## 目标

在 Apple Silicon Mac mini 上，按本仓库 [README](../README.md) 的步骤安装并验证：

- 原生 `arm64` 的 `whisper.cpp v1.9.2`；
- Release + Metal 构建；
- 经 SHA-256 校验的 `ggml-large-v3-turbo.bin`；
- `0.0.0.0:8080` 上的 `POST /v1/audio/transcriptions`；
- `GET /health` 和远程 multipart 转写。

不要扩展到 Core ML、OpenWhispr 配置、`launchd` 或公网反向代理；这些是原调研文档后续步骤。

## 执行原则

1. 所有脚本都以登录的普通用户运行；不要用 `sudo ./install.sh`。
2. 不要把 server 暴露到公网，也不要配置路由器端口转发。
3. 遇到已有目录、未提交源码修改、checksum 不符或端口占用时，先报告，不要删除或覆盖。
4. Homebrew 首次安装、macOS 更新、Application Firewall 修改可能需要管理员授权；构建、下载模型和运行 server 不需要 sudo。
5. 每完成一项，保留命令输出；失败时报告“脚本名 + 完整错误 + 建议的下一步”。

## 推荐执行顺序

先进入本目录：

```bash
cd "$(git rev-parse --show-toplevel)"
```

### A. 系统更新（人工决策，不由安装脚本自动执行）

只检查可用更新：

```bash
softwareupdate --list
```

如果存在 macOS 系统更新，先告知用户可能需要重启。得到同意后再执行系统设置中的更新，或使用用户批准的 `softwareupdate` 命令。不要在未确认时运行带 `--restart` 的命令。

### B. 选择一键安装或分步安装

已有 Homebrew 时：

```bash
./install.sh \
  --audio /真实中文录音路径.m4a \
  --audio /真实英文录音路径.m4a \
  --start
```

没有 Homebrew 时增加 `--install-homebrew`。Homebrew 官方安装器可能要求一次管理员授权：

```bash
./install.sh --install-homebrew \
  --audio /真实中文录音路径.m4a \
  --audio /真实英文录音路径.m4a \
  --start
```

如果用户还没提供录音，可先不带 `--audio`，脚本会用仓库自带的英文 JFK 文件做冒烟测试。但必须把“真实中英文 CLI 验收未完成”列为待办，不能声称第 3 步完全通过。

如需定位问题，按顺序逐个运行：

```bash
./scripts/01-install-dependencies.sh
./scripts/00-preflight.sh
./scripts/02-build-whisper.sh
./scripts/03-download-model.sh
./scripts/04-validate-cli.sh /中文音频 /英文音频
./scripts/05-server.sh start
```

### C. 检查 macOS 防火墙

默认只读检查：

```bash
./scripts/06-firewall.sh
```

仅当防火墙已启用且另一台电脑无法连接、同时本机 `/health` 正常时，执行：

```bash
./scripts/06-firewall.sh --apply
```

脚本只在 `WHISPER_FIREWALL_HELPER` 指向的既有 helper 精确匹配当前 server 路径时使用免密入口。如果 helper 尚未更新，默认会回退为两条精确的交互式 `sudo` 命令。若 `sudo` 报错，报告完整命令和错误；不要自行添加宽泛的 `NOPASSWD: ALL`。

### D. 从另一台电脑验收

把 `client/verify-server.sh` 复制到同一局域网中的另一台电脑，然后运行：

```bash
chmod +x verify-server.sh
./verify-server.sh "http://${WHISPER_LAN_HOST}:8080" /path/to/test-audio.m4a
```

在客户端执行前，将 `WHISPER_LAN_HOST` 设置为服务端 mDNS 主机名或 LAN IP；不要把实际主机名写入仓库。

验收标准：

- `/health` 返回 HTTP 200 且 JSON 为 `{"status":"ok"}`；
- transcription 返回 HTTP 200；
- 返回体是合法 JSON，且 `text` 是非空字符串；
- 人工判断中英文转写内容合理。

若没有第二台电脑，可先在 Mac mini 本机运行同一脚本做服务端冒烟测试，但要明确标记“LAN 路由/防火墙验收尚未完成”。

## 完成后应报告

- macOS 版本、`uname -m`；
- whisper.cpp tag 与 commit；
- 模型路径、大小与 SHA-256；
- CLI 中英文测试结果文件；
- server PID、日志路径、本机和 LAN endpoint；
- 本机 `/health` 结果；
- 另一台电脑的 multipart 转写结果；
- 所有未完成项或 sudo 权限缺口。
