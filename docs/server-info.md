# Whisper Server 部署信息

本文记录当前项目的稳定路径约定和日常管理方式。PID、IP 地址和运行状态会变化，使用文中的检查命令获取实时值，不在文档中固化旧快照。

## 目录布局

默认安装根目录就是仓库根目录；脚本会根据自身位置动态计算，不依赖本地用户名或仓库文件夹名称：

```text
<仓库根目录>
```

| 内容 | 相对安装根目录的路径 | 是否进入 Git |
|---|---|---|
| 安装脚本 | `install.sh`、`scripts/` | 是 |
| 客户端验收脚本 | `client/verify-server.sh` | 是 |
| 文档 | `README.md`、`docs/` | 是 |
| 本地配置 | `.env` | 否 |
| 配置模板 | `.env.example` | 是 |
| whisper.cpp 源码 | `third_party/whisper.cpp` | 否 |
| 构建目录 | `build/whisper.cpp` | 否 |
| server | `build/whisper.cpp/bin/whisper-server` | 否 |
| CLI | `build/whisper.cpp/bin/whisper-cli` | 否 |
| 模型 | `models/ggml-large-v3-turbo.bin` | 否 |
| server 日志 | `var/log/whisper-server.log` | 否 |
| CLI 验收结果 | `var/log/cli-validation/` | 否 |
| PID | `var/run/whisper-server.pid` | 否 |
| 构建/模型状态 | `var/state/` | 否 |

脚本根据自身位置计算仓库根，不依赖仓库文件夹名称。要覆盖默认目录、端口或线程数：

```bash
cp .env.example .env
# 然后只修改 .env；它已被 .gitignore 排除。
```

也可以只为一次命令指定另一个配置文件：

```bash
WHISPER_CONFIG_FILE=/absolute/path/custom.env ./scripts/00-preflight.sh
```

## 固定的软件和模型

```text
whisper.cpp tag: v1.9.2
commit: 306c88f4d1286aec1bf96e544632897886af5501
构建类型: Release
Metal: ON
模型: ggml-large-v3-turbo.bin
模型大小: 1,624,555,275 bytes
模型 SHA-256: 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
```

构建和模型脚本会再次检查这些值。不要为了绕过校验而修改 commit、文件大小或 SHA-256。

## 服务地址

默认监听：

```text
0.0.0.0:8080
```

本机健康检查和转写接口：

```text
GET  http://127.0.0.1:8080/health
POST http://127.0.0.1:8080/v1/audio/transcriptions
```

OpenWhispr 的“服务器 URL”填写 API 基础地址：

```text
http://${WHISPER_LAN_HOST}:8080/v1
```

其中 `WHISPER_LAN_HOST` 来自 `.env`，应设置为服务端的 mDNS 主机名或 LAN IP；
`05-server.sh start` 也会打印自动识别到的 LAN 地址。OpenWhispr 会追加
`/audio/transcriptions`。模型由 server 启动参数固定；客户端发送的模型名只是 OpenAI 兼容占位值，
不会动态切换服务端模型。

## 日常管理

```bash
cd "$(git rev-parse --show-toplevel)"

./scripts/05-server.sh start
./scripts/05-server.sh status
./scripts/05-server.sh logs
./scripts/05-server.sh stop
./scripts/05-server.sh foreground
```

实时检查端口和健康状态：

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
curl --fail --silent --show-error http://127.0.0.1:8080/health
```

脚本启动的后台进程由 `var/run/whisper-server.pid` 管理，并会在停止前核对 PID 对应的命令，避免误杀其他进程。当前方案没有配置 `launchd`，重启 macOS 后需要手动启动。

## 防火墙与权限

默认只读检查：

```bash
./scripts/06-firewall.sh
```

仅在本机健康检查成功而 LAN 连接被 macOS Application Firewall 阻止时运行：

```bash
./scripts/06-firewall.sh --apply
```

脚本会先判断 `WHISPER_FIREWALL_HELPER` 指向的 helper 是否精确匹配当前 server 路径；匹配才使用已有的免密 helper，否则只对当前 server 二进制执行两条明确的防火墙命令，并可能要求管理员密码。不要配置宽泛的 `NOPASSWD: ALL`。

服务本身始终以普通用户运行。由于 `--convert` 会让 FFmpeg 处理上传文件，本服务只适合可信 LAN，不能直接暴露到互联网。
