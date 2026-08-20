
# whisper-on-demand-gateway

whisper-on-demand-gateway 是一个面向可信局域网的轻量 C++17 HTTP 网关。网关进程常驻并负责
对外提供 OpenAI 风格的转写入口，但不会在启动时加载 Whisper 模型；只有收到转写请求时，才在
本机回环地址按需启动 whisper-server。请求完成且连续空闲达到阈值后，模型后端会被安全回收，
以降低平时的内存占用。

网关没有认证、TLS 或公网防护能力，只适合放在受控 LAN 中使用。后端管理接口始终绑定回环地址，
不能把后端端口暴露给局域网或互联网。

## 架构

~~~text
OpenWhispr / curl
        |
        | 可信 LAN，0.0.0.0:8080
        v
whisper-on-demand-gateway       常驻，不加载模型
        |
        | 本机回环，127.0.0.1:18080
        v
whisper-server                  按请求启动，空闲退出
        |
        v
ggml-large-v3-turbo.bin
~~~

默认基线如下：

| 项目 | 默认值/约束 |
|---|---|
| 平台 | macOS Apple Silicon (arm64) |
| whisper.cpp | v1.9.2 |
| 固定 commit | 306c88f4d1286aec1bf96e544632897886af5501 |
| 模型 | large-v3-turbo |
| 模型大小 | 1624555275 bytes |
| 模型 SHA-256 | 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 |
| 网关监听 | 0.0.0.0:8080 |
| 后端监听 | 127.0.0.1:18080 |
| 默认空闲回收 | 300 秒 |
| 默认单请求超时 | 900 秒 |

正式服务的模型唯一权威路径是：

~~~text
~/Library/Application Support/whisper-custom-host/runtime/models/ggml-large-v3-turbo.bin
~~~

模型由 scripts/03-download-model.sh 下载、校验和迁移；不要在 gateway/ 或仓库 models/ 下
另放一份未验收模型。

## 源码结构

| 文件 | 职责 |
|---|---|
| main.cpp | 解析参数、启动前校验、进程退出码 |
| config.h/.cpp | CLI、环境变量和默认值；路径重派生及范围校验 |
| http_gateway.h/.cpp | HTTP 路由、请求限制、上传暂存、后端转发、信号处理 |
| backend_controller.h/.cpp | 后端状态机、请求租约、启动/健康检查、空闲回收和退避 |
| platform_process.h/.cpp | macOS posix_spawn、进程身份记录、信号和回收 |
| support.h/.cpp | JSON/HTTP 辅助、临时文件、时间 deadline、bounded queue 和日志 |
| CMakeLists.txt | gateway_core、网关可执行文件、CTest 和 sanitizer 配置 |

相关脚本和验证入口：

| 路径 | 用途 |
|---|---|
| scripts/07-build-on-demand-gateway.sh | 校验 pinned commit/header，构建并原子发布已验证网关 |
| scripts/08-on-demand-service.sh | 安装、启动和维护当前用户 LaunchAgent |
| launchd/com.local.whisper-on-demand-gateway.plist.in | LaunchAgent 唯一模板 |
| tests/on-demand-integration.sh | 15 个 loopback 生命周期/HTTP 场景 |
| client/verify-server.sh | 从另一台 LAN 电脑做端到端冷启动验证 |
| scripts/06-firewall.sh | 检查或应用精确网关二进制的防火墙规则 |

## 运行逻辑

### 启动阶段

1. 读取配置，优先级为 CLI > 环境变量 > 默认值；确定 root/source 后再派生二进制、模型、
   PID、上传和日志路径。
2. 拒绝以 root 运行，并校验 whisper-server、模型、固定 httplib.h、whisper.cpp commit、
   模型大小和 SHA-256。
3. 创建上传、PID 和日志目录，清理超过 24 小时的旧暂存文件。
4. 绑定 LAN 端口，启动后台 supervisor；初始后端状态为 cold，此时不加载模型。

网关只允许自己的健康、就绪、CORS 预检和转写路由；其他路径返回 404，不会把 whisper-server
的管理路由直接代理到 LAN。

### 请求阶段

对 POST /v1/audio/transcriptions：

1. 请求必须是带合法 boundary 的 multipart/form-data。同时提供 Content-Length 和
   Transfer-Encoding 会返回 400；已知长度超过 WHISPER_MAX_UPLOAD_BYTES 会返回 413。
2. 网关先取得 RequestLease。活动/等待请求达到 WHISPER_MAX_PENDING_REQUESTS 时返回 429，
   不会启动额外后端。
3. 请求体写入权限为 0600 的临时文件。带合法 Content-Length 的请求会在上传期间提前启动后端，
   让模型加载与上传重叠；chunked 请求会先完整暂存并确认总大小，超限时绝不启动后端。
4. 后端按固定身份启动，等其 /health 返回 200 后才转发暂存的 multipart 字节。网关保留原始
   Content-Type，因此 multipart boundary 和 part header 不会被重新拼装。
5. 后端响应体和状态码转回客户端；请求完成后删除暂存文件。每个请求都有统一 deadline，客户端
   断开时不会继续启动或等待无法使用的后端。

后端状态流转为：

~~~text
cold --收到转写--> starting --后端 /health=200--> ready
  ^                       |                         |
  |                       | 启动失败/异常退出       | 空闲达到阈值
  |                       v                         v
  +-------------------- backoff <------------- stopping
~~~

backoff 会在 WHISPER_START_FAILURE_BACKOFF_SECONDS 后允许再次尝试。停止或回收前会重新校验
PID、二进制、模型、端口和当前用户身份；身份不匹配时拒绝发送信号。优雅退出超过关闭超时后，
只有身份仍精确匹配才会升级为 SIGKILL。

## HTTP 接口

外部客户端使用网关地址，后端地址只供网关内部使用：

~~~text
http://<Mac-mini-host-or-IP>:8080/v1
~~~

| 方法和路径 | 成功响应 | 说明 |
|---|---:|---|
| GET /health | 200 | 网关存活检查；返回 backend、活动请求和退避/空闲信息，不触发模型加载 |
| GET /ready | 200/503 | 仅后端 ready 时返回 200；冷态、启动中或退避时返回 503 |
| OPTIONS /v1/audio/transcriptions | 204 | CORS 预检，不触发模型加载 |
| POST /v1/audio/transcriptions | 后端状态码 | 接收 multipart 音频，冷态时启动后端并转发 |
| 其他路径/方法 | 404/405 | 不开放其他后端路由 |

错误响应为 JSON，并带 X-Request-Id；暂时不可用的响应会带 Retry-After。例如：

~~~bash
curl --fail --show-error \
  --form 'file=@/absolute/path/audio.m4a' \
  --form 'model=whisper-1' \
  --form 'response_format=json' \
  'http://<Mac-mini-host-or-IP>:8080/v1/audio/transcriptions'
~~~

curl -F/--form 会自动生成 boundary，不要手工覆盖 Content-Type。model=whisper-1 是兼容
OpenAI 风格客户端的字段，不会改变服务端固定使用的 large-v3-turbo 模型。

典型健康检查：

~~~bash
curl --fail 'http://127.0.0.1:8080/health'
curl --fail 'http://127.0.0.1:8080/ready'
~~~

冷态 /health 正常而 /ready 返回 503 是预期行为；不要为了转写请求先等待 /ready，首个
转写 POST 会负责唤醒后端。

## 配置

先在仓库根目录创建本机配置：

~~~bash
cp .env.example .env
~~~

按需模式使用以下参数；未设置时采用 .env.example 中的默认值：

| 变量 | 默认值 | 作用 |
|---|---:|---|
| WHISPER_GATEWAY_PORT | 8080 | LAN 网关端口 |
| WHISPER_BACKEND_PORT | 18080 | 回环后端端口，不能与网关相同 |
| WHISPER_IDLE_TIMEOUT_SECONDS | 300 | 无活动请求后回收后端的时间 |
| WHISPER_STARTUP_TIMEOUT_SECONDS | 180 | 等待后端启动/就绪的上限 |
| WHISPER_SHUTDOWN_TIMEOUT_SECONDS | 15 | 后端优雅退出等待时间 |
| WHISPER_REQUEST_TIMEOUT_SECONDS | 900 | 单个上传、启动和转发请求的总 deadline |
| WHISPER_MAX_PENDING_REQUESTS | 4 | 活动/等待请求上限 |
| WHISPER_MAX_UPLOAD_BYTES | 268435456 | 单次上传上限（256 MiB） |
| WHISPER_START_FAILURE_BACKOFF_SECONDS | 10 | 启动失败后的重试退避 |
| WHISPER_APP_SUPPORT_ROOT | ~/Library/Application Support/whisper-custom-host | 最小运行时和模型根目录 |

WHISPER_LAN_HOST 只用于客户端 URL、验收和防火墙/SSH 配置；它不是网关 bind 地址。按需模式
的 host 拓扑固定为 0.0.0.0 和 127.0.0.1，不要通过 .env 把后端改成 LAN 地址。
WHISPER_HOST/WHISPER_PORT 是 direct 模式配置，不能用来改变按需网关拓扑。

手动直接运行网关时，也可以使用 gateway --help 查看完整 CLI。除端口和超时外，启动校验还需要
通过参数或环境变量提供 server、模型、pinned header、commit、模型大小/SHA、上传目录、PID
文件和后端日志路径；实际部署应优先使用 scripts/08-on-demand-service.sh，避免漏传身份参数。

## 构建、安装与验证

完整安装流程（会完成依赖、whisper.cpp、模型、网关和 LaunchAgent）：

~~~bash
./install.sh --on-demand --start
~~~

没有 Apple Silicon Homebrew 时可使用：

~~~bash
./install.sh --install-homebrew --on-demand --start
~~~

不立即启动时去掉 --start。也可以在已有 whisper.cpp 构建和模型的情况下分步执行：

~~~bash
./scripts/07-build-on-demand-gateway.sh
./scripts/08-on-demand-service.sh install
./scripts/08-on-demand-service.sh start
~~~

前置条件是 macOS Apple Silicon、Xcode Command Line Tools、Git、CMake、FFmpeg、curl 和可用的
固定模型。服务以当前普通用户运行；不要用 sudo 启动网关或 whisper-server。

07-build-on-demand-gateway.sh 会在发布前：

1. 核对 whisper.cpp 固定 commit 以及 examples/server/httplib.h 的 Git blob，拒绝修改过的 pinned header；
2. 做 CMake Release 构建、3 个 CTest、--help 检查和 15 个临时 loopback 集成场景；
3. 用 ASan/UBSan 构建并再次执行 CTest 与 15 个集成场景；
4. 只有所有检查成功后，才把二进制和 gateway-build.txt 原子发布到 build/on-demand/。

单独运行已构建产物的 loopback 集成测试：

~~~bash
./tests/on-demand-integration.sh \
  --gateway ./build/on-demand/bin/whisper-on-demand-gateway
~~~

从另一台可信 LAN 电脑验证冷启动、空闲回收和二次唤醒：

~~~bash
./client/verify-server.sh --on-demand --idle-timeout 300 \
  'http://<Mac-mini-host-or-IP>:8080' /path/to/test-audio.m4a
~~~

本地 loopback 测试不能替代跨机器 LAN 验证，也不能证明防火墙规则已经应用。

## 运行时部署结构

仓库中的审计构建产物位于 build/on-demand/；LaunchAgent 执行的是校验后原子部署到
WHISPER_APP_SUPPORT_ROOT 的最小运行时副本，不直接从受 macOS TCC 保护的仓库目录启动：

~~~text
~/Library/Application Support/whisper-custom-host/
├── bin/
│   ├── whisper-on-demand-gateway
│   ├── whisper-server
│   └── lib*.dylib
└── runtime/
    ├── models/
    │   ├── ggml-large-v3-turbo.bin
    │   └── model.txt
    ├── whisper.cpp/examples/server/httplib.h
    ├── whisper.cpp/.git/HEAD             # pinned commit attestation
    ├── run/
    │   ├── whisper-on-demand-gateway.pid
    │   ├── whisper-on-demand-backend.pid
    │   └── uploads/
    └── log/
        └── whisper-on-demand-backend.log
~~~

LaunchAgent 文件和其标准输出/错误日志分别位于：

~~~text
~/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist
~/Library/Logs/whisper-custom-host/whisper-on-demand-gateway.stdout.log
~/Library/Logs/whisper-custom-host/whisper-on-demand-gateway.stderr.log
~~~

## 常见维护入口

所有以下命令都在仓库根目录执行：

~~~bash
# 查看 launchd、PID、监听端口、health 和后端状态
./scripts/08-on-demand-service.sh status

# 跟踪日志：gateway|backend|launchd|all
./scripts/08-on-demand-service.sh logs all
./scripts/08-on-demand-service.sh logs gateway
./scripts/08-on-demand-service.sh logs backend

# 停止/启动；start 会重新校验模型和已验证网关
./scripts/08-on-demand-service.sh stop
./scripts/08-on-demand-service.sh start

# 停止并删除本工具生成的 plist；模型、构建和运行日志保留
./scripts/08-on-demand-service.sh uninstall

# 不接入 launchd 的前台排障模式（使用前先 stop）
./scripts/08-on-demand-service.sh foreground
~~~

更新网关代码或 whisper.cpp 后，先重新运行 07-build-on-demand-gateway.sh，再运行
08-on-demand-service.sh install/start。服务脚本会核对二进制和 header SHA-256、模型完整性及
commit，并拒绝覆盖不是本工具生成的 plist。它也会拒绝占用 direct 模式或未知进程的端口，绝不
自动 kill 其他服务。

防火墙只放行 Application Support 中实际执行的精确网关路径：

~~~bash
./scripts/06-firewall.sh --target on-demand
./scripts/06-firewall.sh --target on-demand --apply
~~~

--apply 可能需要管理员授权；不要为此配置 NOPASSWD: ALL。上传会触发 FFmpeg/模型处理，
因此不要做路由器端口转发。LaunchAgent 属于当前登录用户，不应被当作无用户会话的系统级服务；
注销/登录边界和跨 LAN 行为应按上面的验证脚本实际验收。

常见排障顺序：

1. /health 不可访问：运行 status 和 logs all，确认 LaunchAgent 已加载、网关 PID 和 8080
   监听属于本工具。
2. /health 为 200 但 /ready 为 503：冷态或模型加载期间正常；若持续失败，检查后端日志、
   模型 size/SHA 和 whisper.cpp commit。
3. 返回 400/413：确认请求是 multipart 且使用 curl -F；413 表示超过
   WHISPER_MAX_UPLOAD_BYTES。
4. 端口占用：先用 status/lsof 查清进程身份；服务脚本不会替你停止未知进程。
