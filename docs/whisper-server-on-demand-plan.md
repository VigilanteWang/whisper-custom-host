# whisper-server 按需启动与空闲退出改造计划

## 1. 文档状态

- 状态：设计完成，尚未实施。
- 编写日期：2026-08-17。
- 适用基线：当前安装套件中的 `whisper.cpp v1.9.2`，commit
  `306c88f4d1286aec1bf96e544632897886af5501`。
- 目标机器：Apple Silicon Mac mini，服务仅供可信局域网使用。
- 本计划只描述后续改造与验收，不代表按需服务已经安装或验证。

文中的 LAN 主机名/IP 和 macOS 用户均为部署时配置，不在仓库中固化：使用 `.env` 的
`WHISPER_LAN_HOST` 和 `WHISPER_SERVICE_USER`，前者默认动态读取当前主机名，后者默认当前登录用户。

## 2. 目标和“call”的定义

目标是在保留现有客户端地址的前提下，把约 1.5 GiB 模型从“server 常驻时一直占用内存”改成：

1. 平时只有一个轻量 HTTP 网关监听 `0.0.0.0:8080`；
2. 收到第一个转写 call 时，网关启动 `whisper-server`，等待模型加载完成；
3. 触发启动的请求不会丢失，而是在网关中等待，后端就绪后再被转发；
4. 只要还有上传、等待或推理中的请求，就绝不停止后端；
5. 最后一项转写工作完成后持续无新转写请求 300 秒，结束 `whisper-server`；
6. 下一次转写 call 再重复冷启动流程。

本方案把 call 明确定义为：

```text
POST /v1/audio/transcriptions
```

以下请求不触发模型加载，也不刷新空闲计时：

- `GET /health`：检查公网关是否存活；
- `GET /ready`：检查模型后端当前是否已经就绪；
- `OPTIONS /v1/audio/transcriptions`：CORS 预检。

这样，监控探针不会让 1.5 GiB 模型永久驻留。若某个客户端坚持“只有 `/health` 已经 ready
才肯发送转写请求”，需要在客户端适配阶段单独确认；当前套件的远程验证脚本可以直接改造。

## 3. 当前基线和关键约束

当前 `scripts/05-server.sh` 直接让 `whisper-server` 监听 `0.0.0.0:8080`。模型在进程生命周期内
一直保留，只有手工执行 `stop` 才会释放。

改造必须遵守这些已有事实：

- 外部转写路径必须继续是 `/v1/audio/transcriptions`，避免修改 OpenWhispr 的 Base URL；
- 上传是 `multipart/form-data`，音频字段名必须是 `file`；
- server 端仍要带 `--convert`，由 FFmpeg 处理 m4a/mp3 等格式；
- 模型由 server 启动参数固定，客户端的 `model=whisper-1` 只是兼容字段；
- v1.9.2 的模型上下文带全局互斥锁，多项推理实际串行执行；
- v1.9.2 在初次启动时先加载模型，再绑定 HTTP 端口。因此后端启动期间通常是连接被拒绝，不能假设
  初始阶段一定能从 `/health` 收到 503；
- v1.9.2 接受 `SIGTERM` 后会停止 HTTP server 并释放模型，可作为正常回收路径；
- 服务只能以普通用户运行，不能让网关或 `whisper-server` 以 root 运行；
- 公网关启用 FFmpeg 上传转换，仍然只允许暴露在可信 LAN，不能做路由器端口转发。

## 4. 方案选择

### 4.1 选定方案：常驻轻量网关 + 临时 whisper-server

```text
OpenWhispr / curl
        |
        | LAN, 0.0.0.0:8080
        v
whisper-on-demand-gateway        常驻、无模型
        |
        | loopback, 127.0.0.1:18080
        v
whisper-server                   按需创建、空闲退出
        |
        v
ggml-large-v3-turbo.bin          只在后端存活时占用模型内存
```

对客户端保持不变：

```text
http://${WHISPER_LAN_HOST}:8080/v1
```

内部端口调整为：

```text
公网关：0.0.0.0:8080
后端：  127.0.0.1:18080
```

后端必须只监听回环地址，防止客户端绕过生命周期控制直接访问它。

### 4.2 网关实现形式

网关计划使用一个小型 C++17 可执行文件实现，复用固定版本 whisper.cpp 中已有的
`examples/server/httplib.h`：

- 使用现有 Command Line Tools 的 `clang++` 构建，不增加 Go、Node 或 Python 包依赖；
- 输出独立 Mach-O 文件，例如
  `<项目根>/bin/whisper-on-demand-gateway`；
- macOS Application Firewall 可以只允许这个精确二进制，不必放行通用的 Python 解释器；
- 不修改 `whisper.cpp` 源码和现有 `whisper-server` 二进制，便于回滚和升级时重新审计。

网关源文件属于安装套件自身；`httplib.h` 从已固定 commit 的源码树引用。构建脚本必须先核对
whisper.cpp commit，再编译网关，避免静默使用另一个版本的头文件。

### 4.3 不选方案及原因

| 备选方案 | 不采用的原因 |
|---|---|
| 只给 `whisper-server` 增加空闲退出 | 进程退出后没有任何监听者，下一次 HTTP call 无法到达并重新启动它 |
| 直接用 launchd socket activation 启动现有 server | 现有 server 不接收 launchd 传入的监听 socket，而会自行 bind，同一端口会冲突 |
| 用轮询脚本按端口流量启停 | 首个请求到达时端口不存在，请求已经失败；并发和竞态也难以正确处理 |
| 保留进程、调用 `/load` 卸载模型 | v1.9.2 没有对等的安全“卸载但保持 HTTP 服务”接口，且 `/load` 暴露有本地路径风险 |
| 修改 whisper.cpp server 内核 | 改动面和后续升级维护成本更大；外部网关已经能满足生命周期目标 |

## 5. 状态机设计

网关内部只允许一个受互斥锁保护的后端状态机：

| 状态 | 含义 | 收到转写 POST 时 |
|---|---|---|
| `COLD` | 没有后端进程 | 本请求登记为 active，发起一次启动，等待 `READY` |
| `STARTING` | 正在加载模型 | 加入等待队列，不重复创建进程 |
| `READY` | 后端可接收请求 | 立即转发到 `127.0.0.1:18080` |
| `STOPPING` | 已开始优雅退出 | 等待旧进程结束，再按一次新的冷启动处理 |
| `BACKOFF` | 最近一次启动失败 | 在退避结束前返回 503；结束后允许下一次请求重试 |

允许的主要转换：

```text
COLD -> STARTING -> READY -> STOPPING -> COLD
           |          |
           v          v
        BACKOFF     BACKOFF（异常退出）
           |
           v
          COLD
```

必须满足的并发不变量：

1. 任意时刻最多存在一个由网关管理的 `whisper-server`；
2. `active_requests > 0` 时禁止进入 `STOPPING`；
3. 冷启动并发请求共享同一个启动结果，不能各自 fork 一个 server；
4. `active_requests` 从接受转写请求开始计数，直到响应完整发送或客户端断开后才减一；
5. 空闲时间从最后一个 active 请求结束时重新计算，而不是从请求开始或推理开始计算；
6. `/health`、`/ready` 和 `OPTIONS` 均不改变 `active_requests` 和最后活动时间。

## 6. 首个请求的处理流程

冷启动请求按以下顺序处理，以同时利用“客户端上传时间”和“模型加载时间”：

1. 校验方法、路径、`Content-Type` 和上传限制；
2. 在状态锁内递增 `active_requests`；
3. 如果状态为 `COLD`，立即创建后端进程；
4. 同时把原始 HTTP request body 分块写入专用临时文件，不解析或重组 multipart；
5. 后端启动线程轮询 `127.0.0.1:18080/health`：
   - 连接失败表示仍可能处于模型加载阶段；
   - HTTP 200 且 `status=ok` 才进入 `READY`；
   - 子进程提前退出或超过启动超时则进入 `BACKOFF`；
6. 上传完成且后端 ready 后，从临时文件按原 `Content-Type`、`Content-Length` 和必要兼容请求头
   转发到后端；
7. 把后端状态码、Content-Type 和响应体返回客户端；
8. 删除临时文件，在所有清理路径中递减 `active_requests`；
9. 如果此时 active 变为 0，记录新的空闲起点。

不得把整段音频无上限地读入内存。网关使用 `httplib` 的 `ContentReader` 流式落盘，并在实际读取
字节数超过上限时中止。默认建议：

```text
WHISPER_MAX_UPLOAD_BYTES=268435456       # 256 MiB
WHISPER_MAX_PENDING_REQUESTS=4
WHISPER_STARTUP_TIMEOUT_SECONDS=180
```

临时文件放在：

```text
<项目根>/var/run/uploads/
```

文件权限使用 `0600`，目录权限使用 `0700`；正常请求结束立即删除，网关启动时清理超过 24 小时的
遗留文件。日志不得记录音频内容或完整转写文本。

## 7. 空闲判定与退出流程

默认空闲阈值：

```text
WHISPER_IDLE_TIMEOUT_SECONDS=300
```

计时线程每 1 秒检查一次，但只有以下条件全部满足时才停止后端：

- 状态为 `READY`；
- `active_requests == 0`；
- 距最后一个转写请求结束已达到 300 秒；
- PID 文件和实际命令行仍指向预期 server 二进制、模型和后端端口。

停止步骤：

1. 锁内把状态从 `READY` 原子切换到 `STOPPING`，防止新请求误转发；
2. 对已验证身份的后端 PID 发送 `SIGTERM`；
3. 等待最多 `WHISPER_SHUTDOWN_TIMEOUT_SECONDS=15`；
4. 正常退出后回收子进程、删除 PID 文件、转为 `COLD`；
5. 若超时，只能在再次确认它仍是网关创建的精确子进程后发送 `SIGKILL`，并写高优先级错误日志；
6. 如果停止期间收到新 POST，该请求等待 `COLD`，然后重新触发启动，不返回伪成功。

因为停止只会发生在 active 为 0 时，正常情况下 `SIGTERM` 不会中断推理。`SIGKILL` 只属于处理
无法正常退出的受管子进程的兜底，不允许基于陈旧 PID 文件杀进程。

## 8. HTTP 契约

### 8.1 `GET /health`

用于检查网关是否活着，不触发模型，始终由网关本身回答：

```json
{"status":"ok","mode":"on-demand","backend":"cold"}
```

`backend` 可取 `cold`、`starting`、`ready`、`stopping`、`backoff`。保留顶层
`"status":"ok"`，因此当前 `client/verify-server.sh` 的 JSON 判断方式仍可兼容。

### 8.2 `GET /ready`

- 后端 `READY`：HTTP 200，`{"status":"ok","backend":"ready"}`；
- 其他状态：HTTP 503，并返回状态和可选 `retry_after_seconds`；
- 不触发启动，不刷新空闲计时。

### 8.3 `POST /v1/audio/transcriptions`

- `COLD`：接住请求、启动后端、等待并转发；
- `STARTING`：在并发上限内等待同一次启动；
- `READY`：直接转发；
- 超出上传限制：HTTP 413；
- 等待请求数超过限制：HTTP 429，并带 `Retry-After`；
- 后端启动失败或超时：HTTP 503，并带 `Retry-After`；
- 后端在转发中异常退出：HTTP 502；
- 网关内部异常：HTTP 500，详细原因只写服务端日志。

请求转发白名单至少保留：

- `Content-Type`（包括 multipart boundary）；
- `Content-Length`；
- `Accept`；
- 一个由网关生成的 `X-Request-Id`。

不要盲目转发 hop-by-hop headers，例如 `Connection`、`Keep-Alive`、`Transfer-Encoding`、
`Upgrade`。响应侧同样过滤 hop-by-hop headers。

### 8.4 不暴露的路由

网关第一版只实现 health、ready、OPTIONS 和 transcription。不要代理以下后端路由：

- `/load`：防止 LAN 客户端要求 server 加载任意本地模型路径；
- `/` 和静态上传页：不是 OpenWhispr 必需项，缩小暴露面；
- 未列出的其他路径统一返回 404。

## 9. 进程管理和 launchd

### 9.1 默认部署：用户 LaunchAgent

使用：

```text
~/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist
```

关键设置：

- `ProgramArguments` 使用全部绝对路径，直接执行网关二进制，不经过 shell；
- `RunAtLoad=true`；
- `KeepAlive=true`，确保轻量网关崩溃后由 launchd 拉起；
- `ProcessType=Background`；
- `ThrottleInterval=10`，防止配置错误时高速重启；
- stdout/stderr 写入安装根目录的日志文件；
- 不设置 root，也不在 plist 中放秘密信息。

LaunchAgent 只保证该用户登录后的服务。若要求“机器重启且无人登录也能接 call”，需要第二阶段改成
`/Library/LaunchDaemons`，plist 用 `UserName=${WHISPER_SERVICE_USER}` 让实际进程仍以普通用户身份运行；安装
系统级 plist 需要一次有明确用途的 sudo。未经用户确认，不在第一轮实施中扩大到 LaunchDaemon。

### 9.2 网关重启后的对账

网关启动时必须检查：

1. PID 文件不存在且后端端口空闲：进入 `COLD`；
2. PID 文件存在，PID、可执行文件、后端端口和模型参数均匹配，且 `/health` ready：接管为
   `READY`，空闲计时从当前时刻重新开始；
3. PID 文件失效：删除陈旧 PID 文件，进入 `COLD`；
4. `127.0.0.1:18080` 被未知进程占用：拒绝启动并进入 `BACKOFF`，只报告证据，不自动 kill；
5. 网关收到 SIGTERM：停止接收新请求，清理自身创建的后端和临时文件，再退出。

## 10. 配置项计划

在 `.env` 增加：

```bash
WHISPER_GATEWAY_HOST="0.0.0.0"
WHISPER_GATEWAY_PORT="8080"
WHISPER_BACKEND_HOST="127.0.0.1"
WHISPER_BACKEND_PORT="18080"
WHISPER_IDLE_TIMEOUT_SECONDS="300"
WHISPER_STARTUP_TIMEOUT_SECONDS="180"
WHISPER_SHUTDOWN_TIMEOUT_SECONDS="15"
WHISPER_MAX_PENDING_REQUESTS="4"
WHISPER_MAX_UPLOAD_BYTES="268435456"
WHISPER_START_FAILURE_BACKOFF_SECONDS="10"
```

兼容处理：

- 现有 `WHISPER_HOST`、`WHISPER_PORT` 在迁移期保留，明确标注为“直接运行模式”；
- 公网关端口仍为 8080；后端绝不能从配置中接受 `0.0.0.0`；
- 所有秒数、端口、字节数和队列数在启动前做严格整数与范围校验；
- 网关启动前继续调用模型大小和 SHA-256 校验，不允许为了缩短冷启动而绕过模型完整性检查；
- 完整 SHA-256 不应在每次 call 上重算，只在安装、显式验证或网关首次启动时执行。

## 11. 文件改造清单

计划新增：

| 文件 | 用途 |
|---|---|
| `gateway/whisper-on-demand-gateway.cpp` | 网关、状态机、上传暂存、反向代理和子进程管理 |
| `scripts/07-build-on-demand-gateway.sh` | 核对 commit 并用 clang++ 构建网关 |
| `scripts/08-on-demand-service.sh` | install/start/status/logs/stop/uninstall 管理入口 |
| `launchd/com.local.whisper-on-demand-gateway.plist.in` | LaunchAgent 模板 |
| `tests/on-demand-integration.sh` | 冷启动、热请求、空闲退出、并发和故障测试 |

计划修改：

| 文件 | 改动 |
|---|---|
| `.env` | 增加 gateway/backend、timeout、queue 和 upload 配置 |
| `scripts/lib/common.sh` | 派生网关路径、后端 PID、日志和 URL；增加配置校验与 PID 身份检查 |
| `scripts/05-server.sh` | 保留为直接模式/回滚工具；检测网关占用并给出明确切换步骤 |
| `scripts/06-firewall.sh` | 按需模式只允许精确 gateway 二进制，不再把公网关规则指向 whisper-server |
| `client/verify-server.sh` | 接受 cold health，测量首请求冷启动，验证空闲退出后再次唤醒 |
| `install.sh` | 增加显式 `--on-demand` 安装入口；第一版不静默改变默认运行模式 |
| `README.md` | 增加部署、日常管理、冷启动预期和回滚入口 |
| `docs/execution-handoff.md` | 增加逐阶段证据与不得误报完成的要求 |
| `docs/server-info.md` | 实施成功后更新实际 PID、端口、launchd 和日志信息 |
| `docs/whisper-cpp-server-guide.md` | 说明网关 health/ready 语义与 direct/on-demand 两种模式 |

不得直接覆盖当前脚本行为后再测试。先增加独立入口，在验收全部通过后才把按需模式标记为推荐。

## 12. 防火墙与权限计划

当前 `06-firewall.sh` 和既有免密 helper 精确指向 `whisper-server`。改造后 LAN 监听者变成
`whisper-on-demand-gateway`，所以原规则不等价，不能假设自动继承。

实施时按以下顺序：

1. 只读检查 Application Firewall 状态和现有应用规则；
2. 如果防火墙关闭，不做多余系统修改，但仍完成远程 LAN 验收；
3. 如果防火墙启用，优先请求一次管理员授权，把精确 gateway 二进制 add + unblock；
4. 若要延续免密 helper，需要另行审阅并最小化扩展 helper，只允许固定的 gateway 路径；
5. 不允许放行 `/usr/bin/python3`，也不允许添加 `NOPASSWD: ALL`；
6. `whisper-server` 只监听 loopback 后，可保留旧规则用于 direct 回滚，也可在用户明确批准后清理；
   第一轮改造不自动删除可恢复的旧规则。

构建、网关运行、后端启停和 LaunchAgent 安装均不需要 sudo。只有修改系统 Application Firewall
或升级为 LaunchDaemon 时可能需要管理员权限，执行前必须说明具体用途。

## 13. 日志与可观测性

建议日志路径：

```text
<项目根>/var/log/whisper-on-demand-gateway.log
<项目根>/var/log/whisper-server.log
<项目根>/var/run/whisper-server-backend.pid
<项目根>/var/run/whisper-on-demand-gateway.pid
```

每次状态变化写一行带时间戳的结构化日志，至少包含：

- `event`：start_requested、backend_ready、request_finished、idle_stop、backend_exit、error；
- `request_id`；
- 后端 PID；
- `cold_start_ms`、`request_duration_ms`；
- active/pending 数；
- HTTP 状态或退出码；
- 不含音频正文、multipart 内容和完整转写结果。

`08-on-demand-service.sh status` 应同时报告：

- launchd 是否已加载；
- 公网关 PID 和 `0.0.0.0:8080` 监听者；
- backend 状态、PID 和 `127.0.0.1:18080` 监听者；
- active/pending 数或 health JSON；
- 距离空闲退出的剩余秒数（ready 时）；
- 最近一次启动失败摘要和日志路径。

## 14. 实施阶段

### 阶段 A：测量当前基线

在不改配置的情况下记录：

- direct 模式模型加载时间；
- ready 后 RSS；
- 一段真实中文音频的热请求耗时；
- 现有 `/health`、multipart 响应和 LAN 防火墙结果。

这些数据用于判断新方案是否只增加了预期的冷启动等待。

### 阶段 B：实现和本机测试网关

1. 新增 C++ 网关和构建脚本；
2. 使用临时测试端口，例如 gateway 18081、backend 18082，避免影响现有 8080；
3. 完成状态机、流式暂存、单次 spawn、超时、日志和信号处理；
4. 使用小的测试空闲值 10 秒跑自动化集成测试；
5. 用真实 `large-v3-turbo` 完成一次冷启动和一次热请求。

### 阶段 C：接入管理脚本和 LaunchAgent

1. 扩展配置与 common 库；
2. 生成并校验 plist；
3. `launchctl bootstrap gui/$(id -u)` 加载；
4. 验证网关崩溃后被拉起，且不会产生多个 backend；
5. 验证注销/登录边界并在文档中明确 LaunchAgent 限制。

### 阶段 D：切换正式端口

1. 停止 direct `whisper-server`；
2. 确认 8080 为空，18080 未被未知进程占用；
3. 启动公网关 `0.0.0.0:8080`；
4. 必要时更新 Application Firewall 精确允许项；
5. 从另一台 LAN 机器完成冷启动转写；
6. 等待 300 秒，确认 backend 消失但 gateway 和 8080 仍在；
7. 再发第二个请求，确认可再次唤醒。

### 阶段 E：文档和交接

更新 README、`docs/server-info.md`、使用指南和执行交接文档，附实际命令输出。只有全部验收项有证据后，才把
按需模式写成“已安装/已验证”。

## 15. 验收矩阵

| 编号 | 场景 | 通过标准 |
|---|---|---|
| T01 | cold health | backend 不存在时 `/health` 200，且不创建 backend |
| T02 | cold transcription | 首个真实 multipart 请求最终 200 且 `text` 非空 |
| T03 | single-flight | 同时发 3 个冷请求，只创建一个 backend PID |
| T04 | inference protection | 推理超过空闲阈值时，active 非 0，backend 不退出 |
| T05 | warm reuse | 300 秒内第二个请求复用同一 PID，且不重新加载模型 |
| T06 | idle exit | 最后请求完成 300 秒后 backend PID 和 18080 监听消失 |
| T07 | gateway survival | backend 退出后 gateway PID 和公网 8080 仍存在 |
| T08 | second wake | idle exit 后再次请求成功，并得到新的 backend PID |
| T09 | health neutrality | 每 5 秒探测 health 仍不能阻止 backend 空闲退出 |
| T10 | upload limit | 超限请求返回 413，不遗留临时文件 |
| T11 | queue limit | 超出 pending 上限返回 429，不创建额外 backend |
| T12 | bad model/start failure | 返回 503 并退避，无启动风暴，日志可定位根因 |
| T13 | backend crash | 当前请求得到 502/503；后续请求在退避后能重新启动 |
| T14 | stale PID/foreign port | 不杀未知进程，拒绝启动并报告 PID、命令和端口证据 |
| T15 | client disconnect | active 最终归零，临时文件清理，backend 可按时退出 |
| T16 | CORS OPTIONS | 不启动模型，返回客户端需要的允许头 |
| T17 | LAN verification | 另一台机器用 `curl -F file=@...` 完成冷启动转写 |
| T18 | memory release | idle exit 后 server RSS 消失；只剩轻量 gateway RSS |
| T19 | launchd recovery | 手工终止 gateway 后 launchd 拉起且状态重新对账正确 |
| T20 | rollback | bootout gateway 后，`05-server.sh start` 可恢复 direct 模式 |

远程验证仍须让 curl 自己生成 multipart boundary：

```bash
curl --fail --show-error --max-time 900 \
  --form 'file=@/绝对路径/audio.m4a' \
  --form 'model=whisper-1' \
  --form 'response_format=json' \
  "http://${WHISPER_LAN_HOST}:8080/v1/audio/transcriptions"
```

不得手工设置 multipart `Content-Type`。

## 16. 性能预期和调优顺序

该方案节省的是空闲时的模型内存，不会消除首次请求的模型加载时间。客户端必须允许冷请求等待，
建议总超时继续保持 900 秒。需要在实测后记录：

```text
冷启动时间 = backend spawn 到 /health ready
冷请求耗时 = 网关接受请求到响应完成
热请求耗时 = ready 状态下接受请求到响应完成
回收时间   = 最后请求完成到 backend 进程退出
```

调优顺序：

1. 先以 300 秒 idle、4 个 pending、256 MiB upload 完成正确性验收；
2. 根据实际使用频率调整 idle，建议范围 120–900 秒；
3. 冷启动频繁时先提高 idle，不要直接引入多个大模型进程；
4. 因后端推理有全局互斥锁，增加网关并发只改善上传和等待，不会带来线性推理吞吐；
5. 不在本改造中同时更换模型、启用 Core ML/VAD 或升级 whisper.cpp，以免无法归因。

## 17. 回滚方案

按需方案不覆盖 server 二进制和模型，回滚应在 2 分钟内完成：

1. `08-on-demand-service.sh stop`；
2. `08-on-demand-service.sh uninstall`，只 bootout 并移走用户 plist，不删除日志和二进制；
3. 确认 8080 和 18080 均无残留监听；
4. 执行现有 `./scripts/05-server.sh start`；
5. 验证 `GET /health` 和远程 multipart 转写；
6. 若改过防火墙，保留 gateway 规则不影响 direct 回滚；需要删除规则时另行取得用户确认。

回滚脚本不得删除模型、源码、转写结果或历史日志。

## 18. 实施完成的判定

只有同时满足以下条件才能报告“按需启动方案已完成”：

- 新增/修改文件均通过 shellcheck 或相应编译检查；
- 网关构建产物、commit 关联和配置值有记录；
- 本机 T01–T16、T18–T20 通过；
- 从另一台 LAN 机器完成 T17；
- 真实音频冷请求和二次唤醒都返回非空且合理的转写；
- 空闲 300 秒后明确看到 backend PID、18080 监听和模型 RSS 消失；
- 8080 仍由普通用户的精确 gateway 二进制监听；
- 防火墙、LaunchAgent 登录限制、sudo 使用和所有未完成项已写入交接报告。

如果缺少远程机器、真实音频或管理员防火墙授权，只能报告本机已完成的阶段，不得把对应验收项写成
通过。
