# 原版 whisper.cpp server 功能指南

本文只介绍上游 `whisper.cpp` 的 `examples/server` 示例程序：它如何启动、提供哪些 HTTP
路由、怎样提交音频、可以覆盖哪些识别参数，以及它与 OpenAI Whisper API 的兼容边界。

本文以 `whisper.cpp v1.9.2` 的 `examples/server/README.md` 和
`examples/server/server.cpp` 为准。后续版本可能增加、删除或修改参数；升级后应以对应版本的
`whisper-server --help` 和源码为最终依据。

本文只讨论上游程序的功能，不展开构建系统和生产部署细节。命令中的路径均为示例路径，请替换
成实际的二进制、模型和音频文件路径。

## 1. 它是什么

`whisper-server` 是 `whisper.cpp` 提供的一个轻量 HTTP 示例服务。它启动时加载一个 Whisper
模型，然后接收 HTTP 文件上传，把音频交给 Whisper 推理，并返回转写、翻译或字幕结果。

它的工作流程可以概括为：

1. 从 `--model` 指定的服务器本地文件加载模型。
2. 绑定 `--host` 和 `--port` 指定的监听地址。
3. 通过 multipart/form-data 接收名为 `file` 的音频字段。
4. 使用启动参数作为默认识别配置，并用本次请求中的字段覆盖这些默认值。
5. 执行一次 Whisper 推理，按 `response_format` 返回文本、JSON、SRT 或 VTT。

它不是模型下载器、用户管理系统或完整的生产 API 网关，也不提供训练功能。

## 2. 启动 server

假设二进制位于 `./build/bin/whisper-server`，模型位于
`./models/ggml-base.en.bin`，最小启动命令如下：

```bash
./build/bin/whisper-server \
  --model ./models/ggml-base.en.bin \
  --host 127.0.0.1 \
  --port 8080
```

不显式传入时，v1.9.2 的上游默认值包括：

| 参数 | 上游默认值 | 功能 |
|---|---|---|
| `--host` | `127.0.0.1` | 监听的主机名或 IP 地址 |
| `--port` | `8080` | TCP 端口 |
| `--model` | `models/ggml-base.en.bin` | 启动时加载的模型文件 |
| `--public` | `examples/server/public` | 静态文件目录 |
| `--request-path` | 空 | 所有 HTTP 路由的统一前缀 |
| `--inference-path` | `/inference` | 音频推理路由 |
| `--tmp-dir` | `.` | `--convert` 使用的临时目录 |
| `--convert` | 关闭 | 是否使用 FFmpeg 将上传文件转换为 WAV |

模型必须是 server 能识别的 `ggml` 模型文件。server 不会因为收到请求中的 `model` 字段而
切换模型；启动时的 `--model` 决定初始模型，动态换模使用单独的 `/load` 路由。

### 2.1 网络和静态文件参数

| 参数 | 说明 |
|---|---|
| `--host HOST` | 指定监听地址。`127.0.0.1` 只接受本机连接；是否监听其他地址取决于操作系统网络配置。 |
| `--port PORT` | 指定监听端口。端口被占用或无法绑定时，server 启动失败。 |
| `--public PATH` | 设置静态文件根目录。目录中有网页资源时，可以通过根路径访问；没有可用首页时，server 提供内置的简单上传页面。 |
| `--request-path PATH` | 给根路径、推理、健康检查和换模路由统一增加前缀。 |
| `--inference-path PATH` | 设置推理路由的末尾路径，默认是 `/inference`。 |
| `--tmp-dir PATH` | 设置 FFmpeg 转换产生的临时 WAV 文件目录。目录必须可写。 |
| `--convert` | 先把上传内容写入临时文件，再调用 FFmpeg 转为 WAV；需要 server 进程能够找到 `ffmpeg`。 |

例如：

```text
--request-path /api --inference-path /transcribe
```

会把主要路由组合为：

```text
GET  /api/health
POST /api/transcribe
POST /api/load
```

`--public` 是服务器上的文件目录，不是 URL 前缀；URL 前缀由 `--request-path` 控制。

### 2.2 模型、设备和性能参数

server 的启动参数中有一部分会成为每次请求的默认识别参数：

| 参数 | 功能 |
|---|---|
| `-t, --threads N` | Whisper 推理使用的线程数。 |
| `-p, --processors N` | 并行处理器数量，供 `whisper_full_parallel` 处理一次请求中的音频。它不是 HTTP 客户端并发数。 |
| `-m, --model FNAME` | 模型路径。 |
| `-l, --language LANG` | 语音语言，例如 `en`；使用 `auto` 自动检测。 |
| `-ng, --no-gpu` | 禁用 GPU。 |
| `-dev, --device N` | 选择 GPU 设备编号。 |
| `-fa, --flash-attn` | 启用 Flash Attention。 |
| `-nfa, --no-flash-attn` | 禁用 Flash Attention。 |
| `-oved, --ov-e-device DNAME` | 设置 OpenVINO encoder 使用的设备。没有构建 OpenVINO 时不起作用。 |
| `-dtw, --dtw MODEL` | 启用指定模型预设的 token 级时间戳。 |

这些参数在启动时确定计算环境。单次 HTTP 请求可以覆盖识别策略和输出选项，但不能通过普通
请求字段替换已加载模型或改变 GPU/线程初始化方式。

## 3. HTTP 路由

以下路径假设没有设置 `--request-path`，且保留默认的 `--inference-path /inference`。

| 方法 | 路径 | 功能 |
|---|---|---|
| `GET` | `/` | 提供 `--public` 目录中的静态内容；没有可用首页时返回内置上传页面。 |
| `OPTIONS` | `/inference` | 为推理请求提供预检路由。 |
| `POST` | `/inference` | 上传音频并执行转写或翻译。 |
| `POST` | `/load` | 从 server 所在机器的本地路径重新加载模型。 |
| `GET` | `/health` | 返回模型是否处于可用状态。 |

设置 `--request-path /api` 后，上表中的 `/inference`、`/load`、`/health` 会分别变成
`/api/inference`、`/api/load`、`/api/health`，根页面也位于 `/api/`。

### 3.1 健康检查

模型可用时：

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"ok"}
```

模型正在加载或重新加载时：

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{"status":"loading model"}
```

初次启动时，server 会先初始化模型，再开始监听；因此初次加载阶段通常还没有可访问的 HTTP
监听 socket。`503` 主要会在 server 已经运行、通过 `/load` 重新加载模型时出现。

## 4. 提交推理请求

最小请求：

```bash
curl --fail --show-error \
  --form 'file=@/path/to/audio.wav' \
  --form 'response_format=json' \
  http://127.0.0.1:8080/inference
```

`curl --form` 会自动构造正确的 multipart boundary，通常不要手工覆盖
`Content-Type: multipart/form-data`。

请求必须包含名为 `file` 的 multipart 文件字段。缺少该字段时，server 返回 HTTP 400 和类似
下面的 JSON：

```json
{"error":"no 'file' field in the request"}
```

上游 README 以 WAV 为基本示例。启动时增加 `--convert` 后，server 会把上传内容写入
`--tmp-dir` 下的临时文件，调用 FFmpeg 转成 WAV，再交给 Whisper；因此能够处理哪些非 WAV 格式
取决于 FFmpeg 的能力和输入文件本身。

### 4.1 常用请求字段

除 `file` 外，以下字段可以作为 multipart 文本字段传递。没有传入的字段使用启动时的默认值。

| 字段 | 作用 |
|---|---|
| `response_format` | 选择 `json`、`verbose_json`、`text`、`srt` 或 `vtt`。 |
| `language` | 指定语言，例如 `zh`、`en`；`auto` 表示自动检测。 |
| `detect_language` | 只进行语言检测，不以普通转写为目标。 |
| `translate` | 将语音翻译成英语；Whisper 的目标语言固定为英语。 |
| `prompt` | 初始解码提示，可放入专有名词、缩写或上下文。 |
| `carry_initial_prompt` | 是否在后续内部窗口继续携带初始提示。 |
| `temperature` | 初始采样温度。 |
| `temperature_inc` | 解码回退时增加的温度。 |
| `offset_t` | 从音频的第几个毫秒开始处理。 |
| `duration` | 最多处理多少毫秒；`0` 表示处理剩余音频。 |
| `offset_n` | 字幕或分段编号的偏移量，不是音频时间偏移。 |
| `max_context` | 保留的最大文本上下文 token 数。 |
| `max_len` | 单个分段的最大字符数。 |
| `split_on_word` | 尽量在词边界而不是 token 边界切分。 |
| `best_of` | 贪心采样保留的候选数量。 |
| `beam_size` | 大于 1 时使用 beam search。 |
| `audio_ctx` | 音频上下文长度；`0` 表示使用完整默认上下文。 |
| `word_thold` | 词级时间戳的概率阈值。 |
| `entropy_thold` | 解码失败判定的熵阈值。 |
| `logprob_thold` | 解码失败判定的平均 log probability 阈值。 |
| `no_speech_thold` | 无语音判定阈值。 |
| `no_timestamps` | 不生成时间戳。 |
| `token_timestamps` | 在详细 JSON 中生成 token/词级时间戳。 |
| `suppress_nst` / `suppress_non_speech` | 抑制非语音 token。 |
| `diarize` | 对符合条件的双声道音频进行简单说话人估计。 |
| `tinydiarize` | 使用 tdrz 模型标记说话人切换。 |
| `debug_mode` | 启用调试行为，例如输出中间数据。 |
| `no_language_probabilities` | 不在 `verbose_json` 中计算语言概率，以减少额外开销。 |

布尔字段只有 `true`、`1`、`yes`、`y` 会被解析为真，其他字符串按假处理。建议统一使用
`true` 或 `false`。

### 4.2 请求示例

指定语言、提示词和采样参数：

```bash
curl --fail --show-error \
  --form 'file=@/path/to/audio.wav' \
  --form 'language=zh' \
  --form 'prompt=whisper.cpp，HTTP，术语表' \
  --form 'temperature=0.0' \
  --form 'temperature_inc=0.2' \
  --form 'response_format=json' \
  http://127.0.0.1:8080/inference
```

生成 SRT 字幕：

```bash
curl --fail --show-error \
  --form 'file=@/path/to/audio.wav' \
  --form 'language=auto' \
  --form 'response_format=srt' \
  http://127.0.0.1:8080/inference \
  --output transcript.srt
```

只处理音频中从 60 秒开始的 30 秒：

```bash
curl --fail --show-error \
  --form 'file=@/path/to/long-audio.wav' \
  --form 'offset_t=60000' \
  --form 'duration=30000' \
  --form 'response_format=verbose_json' \
  http://127.0.0.1:8080/inference
```

## 5. 响应格式

### `json`

普通 JSON 响应只包含合并后的转写文本：

```json
{"text":"转写结果"}
```

未识别的响应格式也会回退到包含 `text` 的 JSON 响应。

### `verbose_json`

详细 JSON 用于字幕编辑、时间轴分析或调试。v1.9.2 主要提供：

- `task`：`transcribe` 或 `translate`；
- `language`：识别出的语言；
- `duration`：音频时长，单位为秒；
- `text`：合并后的文本；
- `segments`：分段数组，包含分段编号、文本、起止时间、token、词和概率等信息；
- 默认情况下的语言概率信息。

`no_language_probabilities=true` 可以关闭语言概率计算。该响应尽量接近 OpenAI Whisper 的
Python 格式，但不是字段完全一致的实现。

### `text`

返回纯文本内容。v1.9.2 源码为该响应设置的 Content-Type 是
`text/html; charset=utf-8`，不要仅凭 Content-Type 推断内容一定是 HTML。

### `srt` 和 `vtt`

分别返回 SubRip 和 WebVTT 字幕内容，包含分段时间戳。启用对应的说话人功能时，字幕中还可能
带有说话人标记。

## 6. 动态重新加载模型

`/load` 接收的是 server 所在机器上的模型文件路径，不是上传的模型文件内容：

```bash
curl --fail --show-error \
  --form 'model=/path/to/another-model.bin' \
  http://127.0.0.1:8080/load
```

处理过程是：

1. 从 multipart 字段 `model` 读取本地路径。
2. 检查该路径是否存在。
3. 释放当前 Whisper context。
4. 从新路径初始化模型。
5. 成功后把健康状态恢复为 ready。

路径缺失或文件不存在时返回 HTTP 400。v1.9.2 在新模型初始化失败且没有旧模型可恢复时会退出
进程；某些 `/load` 失败路径还可能让健康状态停留在 loading，因此应同时检查响应和日志。
不应把 `/load` 暴露给不可信客户端，也不应把客户端传入的字符串当作安全的模型选择器。换模前
应在服务端验证路径、文件权限、模型来源和完整性。

## 7. VAD、说话人标记和时间戳

### 7.1 VAD

启动参数：

| 参数 | 作用 |
|---|---|
| `--vad` | 启用 Voice Activity Detection。 |
| `-vm, --vad-model FNAME` | VAD 模型路径。 |
| `-vt, --vad-threshold N` | 语音概率阈值。 |
| `-vspd, --vad-min-speech-duration-ms N` | 最短语音片段时长。 |
| `-vsd, --vad-min-silence-duration-ms N` | 用于切段的最短静音时长。 |
| `-vmsd, --vad-max-speech-duration-s N` | 单段最长语音时长，过长时自动切段。 |
| `-vp, --vad-speech-pad-ms N` | 在语音段前后补齐的毫秒数。 |
| `-vo, --vad-samples-overlap N` | 相邻语音段的重叠秒数。 |

请求可以通过 `vad` 及相关字段覆盖 VAD 参数，但 VAD 模型路径由启动参数提供。只传
`vad=true` 而没有可用 VAD 模型，不能正常完成 VAD 推理。

### 7.2 说话人相关功能

- `diarize` 是基于左右声道能量的简单估计，适合两个说话人分别占用左右声道的录音，不是对
  一条混合单声道录音进行通用多人识别。
- `tinydiarize` 需要配套的 tdrz 模型，只标记说话人切换。
- `diarize` 和 `tinydiarize` 不能同时使用。

### 7.3 时间戳

默认输出包含分段时间戳。`no_timestamps=true` 可以关闭时间戳；`token_timestamps=true` 会在
详细 JSON 中保留更细的 token/词级时间信息。`--dtw` 用于选择 token 级时间戳的 DTW 模型预设。

## 8. 并发、超时和错误行为

v1.9.2 的 server 具有以下实现特征：

- server 进程通常只加载一个 Whisper context；每个请求从启动时的默认参数复制一份，因此请求
  覆盖不会永久修改下一次请求的默认识别参数。
- 推理和 `/load` 共用同一把模型互斥锁。多个 HTTP 请求可以同时到达，但模型推理部分会按锁
  串行执行；`--processors` 是单次请求内部的处理参数，不等于 HTTP 并发数。
- HTTP 读超时和写超时在该版本源码中固定为 600 秒，没有对应的命令行参数。
- 客户端在推理过程中断开连接时，server 会尝试中止推理，并可能返回 HTTP 499。
- `--print-realtime` 是控制台输出选项，不会把 HTTP 响应变成 token 流；客户端要等推理完成后
  才能取得最终响应。
- server 设置了 `Access-Control-Allow-Origin: *` 等默认响应头，但这不等于身份认证或访问控制。

常见状态：

| 状态 | 常见原因 |
|---:|---|
| `400` | 缺少 `file`、音频无法读取、模型路径不存在或请求参数无法解析。 |
| `404` | URL 没有使用实际的 `--request-path` / `--inference-path` 组合。 |
| `499` | 客户端在推理完成前断开连接。 |
| `500` | FFmpeg 转换失败、推理失败或处理异常。 |
| `503` | server 正在通过 `/load` 加载模型。 |

## 9. OpenAI API 兼容边界

该 server 提供的是 OpenAI 风格的轻量转写接口，而不是完整 OpenAI API：

- 可以通过 `--request-path` 和 `--inference-path` 组合出类似 `/v1/audio/transcriptions` 的
  路径；
- 使用 multipart 的 `file` 和 `response_format` 字段；
- `json` 响应包含 `text` 字段；
- `verbose_json` 尽量提供类似的分段结构；
- 不提供完整的 `/v1/models` 等模型管理 API；
- 不提供 API key、`Authorization` 校验、用户隔离、配额或速率限制；
- 不提供 TLS；
- 没有独立的音频翻译路由，翻译通过 `translate=true` 完成；
- 不提供 token 级 HTTP 流式响应；
- 响应字段和 Content-Type 不保证与 OpenAI 官方服务完全一致。

因此，客户端需要能够自定义 base URL 和 multipart 字段时，通常可以尝试接入；依赖完整鉴权、
模型列表、严格响应 schema 或流式协议的客户端，需要额外的适配层。

## 10. 安全边界

这是一个接收用户文件上传的示例服务，并且 `--convert` 会调用 FFmpeg。官方 README 建议不要
以管理员权限运行，并应在隔离、可信的环境中使用。

部署时至少应注意：

- 使用普通用户运行，不使用 `sudo whisper-server`；
- 不把没有认证和 TLS 的原版 server 直接暴露给不可信网络；
- 开启 `--convert` 前确认 FFmpeg 版本、执行路径和临时目录权限；
- 限制能够访问 `/load` 的人员，因为该路由读取服务端本地路径并替换模型；
- 对上传大小、格式、文件名和网络访问范围增加外层限制；
- 如果需要公网、多用户或生产级 API，应在前面增加带 TLS、认证、限流、审计和资源隔离的网关。

## 11. 排查思路

### 根路径打开不是预期页面

检查 `--public` 指向的目录和 `--request-path`。`--public` 是文件系统目录，不能用来设置 URL
前缀；如果目录没有可用首页，server 才会使用内置页面。

### 推理返回 400

确认请求使用 multipart，并且文件字段名严格为 `file`：

```bash
curl --fail --show-error \
  --form 'file=@/path/to/audio.wav' \
  http://127.0.0.1:8080/inference
```

如果使用了 `--convert`，再检查 `ffmpeg` 是否可执行、临时目录是否可写，以及输入格式是否能被
FFmpeg 解码。

### 请求一直等待

检查是否有其他请求正在占用模型互斥锁、上传或转换是否仍在进行，以及音频是否过长。增加客户端
超时不能解决 server 内部推理或资源竞争问题。

### `/health` 返回 503

这表示 server 正在加载或重新加载模型。检查 `/load` 请求、模型文件和 server 日志；如果换模
失败，不能假设状态一定会自动恢复为 `{"status":"ok"}`。

### 客户端请求 404

根据启动参数重新拼出路径：

```text
完整推理路径 = --request-path + --inference-path
健康检查路径 = --request-path + /health
换模路径     = --request-path + /load
```

## 12. 官方依据

- [whisper.cpp v1.9.2 主 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/README.md)
- [whisper-server v1.9.2 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/README.md)
- [whisper-server v1.9.2 源码](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/server.cpp)
- [v1.9.2 模型说明](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md)
- [whisper.cpp v1.9.2 Release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2)

本地安装的二进制和未来版本的最终参数，以实际帮助为准：

```bash
whisper-server --help
```
