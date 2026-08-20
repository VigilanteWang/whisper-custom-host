# whisper.cpp 与 whisper-server 使用详解

本文针对本机已经安装的 `whisper.cpp v1.9.2`，说明它是什么、如何使用
`whisper-cli` 做单次转写、如何启动和调用 `whisper-server`，以及各类常用参数的实际含义。

> 版本边界：本文以 tag `v1.9.2`、commit
> `306c88f4d1286aec1bf96e544632897886af5501` 为准。后续版本可能增加、删除或修复参数，升级后应重新运行
> `whisper-cli --help` 和 `whisper-server --help` 核对。

本文中的命令默认从仓库根目录执行。为避免绑定某台电脑的用户名或绝对路径，先加载本地配置：

```bash
cd "$(git rev-parse --show-toplevel)"
if [[ -f .env ]]; then source .env; else source .env.example; fi
```

`WHISPER_INSTALL_ROOT` 和 `WHISPER_LAN_HOST` 均可在 `.env` 中覆盖；后者应填写服务端
可被 LAN 客户端访问的 mDNS 主机名或 IP。

## 1. 当前安装概况

| 项目 | 当前值 |
|---|---|
| 机器 | Apple Silicon Mac mini M4，`arm64` |
| whisper.cpp | `v1.9.2` |
| 构建类型 | `Release` |
| GPU 后端 | Metal 已启用 |
| CPU 加速 | Apple Accelerate/BLAS 已启用 |
| Core ML | 未启用 |
| 模型 | `ggml-large-v3-turbo.bin`，多语言，约 1.5 GiB |
| server 配置监听 | `0.0.0.0:8080` |
| 健康检查 | `GET /health` |
| 转写接口 | `POST /v1/audio/transcriptions` |
| 格式转换 | server 启用了 `--convert`，通过 FFmpeg 转换上传文件 |

本机主要路径：

```text
安装根目录：${WHISPER_INSTALL_ROOT}
源码目录：  ${WHISPER_INSTALL_ROOT}/third_party/whisper.cpp
CLI：       ${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-cli
Server：    ${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-server
模型：      ${WHISPER_APP_SUPPORT_ROOT}/runtime/models/ggml-large-v3-turbo.bin
模型状态：  ${WHISPER_APP_SUPPORT_ROOT}/runtime/models/model.txt
```

默认 `WHISPER_APP_SUPPORT_ROOT` 为
`~/Library/Application Support/whisper-custom-host`。因此唯一权威模型文件是：

```text
~/Library/Application Support/whisper-custom-host/runtime/models/ggml-large-v3-turbo.bin
```

`scripts/03-download-model.sh` 负责在该最终路径下载、完整校验或迁移模型，并把 `model.txt` 写在模型
同目录。`scripts/04-validate-cli.sh`、`scripts/05-server.sh`（direct）和
`scripts/08-on-demand-service.sh`（on-demand）全部引用同一个 `MODEL_FILE`，三种运行模式不再各自维护
模型文件。

仓库 `models/` 不再存放正式模型。若发现旧版
`${WHISPER_INSTALL_ROOT}/models/ggml-large-v3-turbo.bin`，03 脚本会先分别校验旧文件与新权威文件；只有
两边都匹配固定 size 和 SHA-256 才删除旧文件。任一校验失败都会保留旧文件并停止迁移。

日常只需执行：

```bash
./scripts/03-download-model.sh
```

不要手工在仓库与 Application Support 之间维护两份正式模型。

本轮三条真实 JFK 路径均已成功：

| 路径 | 结果 |
|---|---|
| CLI（04） | 使用唯一权威模型生成有效 JFK 转写 |
| direct HTTP（05） | 使用同一模型完成 JFK 转写 |
| on-demand HTTP（08） | 使用同一模型返回 HTTP 200；最终耗时 6.82 秒 |

这些是本机验收证据；Application Support gateway 的 firewall allow 仍待重新 apply，T17 跨机器验证
仍未完成。

## 2. whisper.cpp 是什么

`whisper.cpp` 是 OpenAI Whisper 自动语音识别模型的 C/C++ 推理实现。它负责加载转换成
`ggml` 格式的模型，在本机 CPU、GPU 或其他已编译后端上执行：

- 语音转文字；
- 自动语言识别；
- 把非英语语音翻译成英语；
- 生成分段或词级时间戳；
- 输出纯文本、JSON、SRT、VTT 等格式；
- 可选 VAD（语音活动检测）和有限的说话人分段功能。

它只做推理，不负责训练模型。`whisper-cli` 和 `whisper-server` 都是基于同一底层
Whisper 上下文的示例程序：前者适合本机批处理，后者把推理包装成 HTTP 服务。

## 3. 模型如何选择

官方 `ggml` 模型大致如下：

| 系列 | 大致磁盘占用 | 特点 |
|---|---:|---|
| `tiny` | 75 MiB | 最快、资源占用最低，准确率也最低 |
| `base` | 142 MiB | 轻量任务 |
| `small` | 466 MiB | 速度和准确率的中间档 |
| `medium` | 1.5 GiB | 更高准确率，推理更慢 |
| `large-v3` | 2.9 GiB | 高准确率，资源需求高 |
| `large-v3-turbo` | 1.5 GiB | large-v3 的加速版本；当前服务器使用它 |
| `large-v3-turbo-q5_0` | 547 MiB | 量化版本，占用更小，可能有一定精度折损 |

选择原则：

- 中文或多语言任务不要使用名称带 `.en` 的英语专用模型。
- 当前 M4 上的 `large-v3-turbo` 是准确率、速度、内存占用之间较合理的默认选择。
- 资源不足时优先尝试量化模型；量化降低磁盘和内存占用，但需要自行验收准确率。
- 客户端请求里的 `model=whisper-1` **不会切换当前 server 的模型**。真正模型由 server
  启动时的 `--model` 固定，除非调用 `/load` 动态重载。

## 4. whisper-cli：本机单次或批量转写

### 4.1 最小命令

```bash
"${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-cli" \
  --model "${WHISPER_APP_SUPPORT_ROOT}/runtime/models/ggml-large-v3-turbo.bin" \
  --language auto \
  --file /绝对路径/audio.wav
```

也可以把一个或多个输入文件写在命令末尾：

```bash
whisper-cli --model /path/to/model.bin first.wav second.wav
```

当前二进制帮助列出的直接输入格式为 `flac`、`mp3`、`ogg`、`wav`。对于 `m4a`、视频或其他
格式，先转为 16 kHz、单声道、16-bit PCM WAV 最稳妥：

```bash
ffmpeg -i input.m4a -ar 16000 -ac 1 -c:a pcm_s16le output.wav
```

### 4.2 常见输出

```bash
# 只在终端输出结果，不显示运行日志
whisper-cli -m /path/to/model.bin -f input.wav --no-prints

# 同时生成 output.txt
whisper-cli -m /path/to/model.bin -f input.wav --output-txt --output-file output

# 生成字幕
whisper-cli -m /path/to/model.bin -f input.wav --output-srt --output-file output
whisper-cli -m /path/to/model.bin -f input.wav --output-vtt --output-file output

# 生成详细 JSON
whisper-cli -m /path/to/model.bin -f input.wav --output-json-full --output-file output
```

`--output-file` 不含扩展名；程序会根据输出类型添加 `.txt`、`.srt`、`.vtt`、`.json` 等。

### 4.3 CLI 参数分类

#### 输入、模型和设备

| 参数 | 默认值 | 含义与建议 |
|---|---:|---|
| `-f, --file FNAME` | 空 | 输入音频；也可直接使用位置参数 |
| `-m, --model FNAME` | `models/ggml-base.en.bin` | 上游二进制的相对默认值；本套件不使用它，始终明确指定唯一权威模型 |
| `-l, --language LANG` | `en` | 输入语言；多语言场景使用 `auto`，已知中文可用 `zh` |
| `-dl, --detect-language` | 关闭 | 只检测语言后退出 |
| `-ng, --no-gpu` | 关闭 | 禁用 GPU；通常只用于对比或排障 |
| `-dev, --device N` | `0` | 选择 GPU 设备 |
| `-fa, --flash-attn` | 开启 | 启用 Flash Attention |
| `-nfa, --no-flash-attn` | 关闭 | 遇到兼容或结果异常时用于对照排障 |
| `-oved, --ov-e-device` | `CPU` | OpenVINO encoder 设备；本机未构建 OpenVINO，一般无效 |

#### 截取、上下文和分段

| 参数 | 默认值 | 含义与建议 |
|---|---:|---|
| `-ot, --offset-t N` | `0` | 从第 N 毫秒开始处理 |
| `-d, --duration N` | `0` | 最多处理 N 毫秒；`0` 表示处理到结尾 |
| `-on, --offset-n N` | `0` | 输出字幕或分段编号的偏移，不是音频时间偏移 |
| `-mc, --max-context N` | `-1` | 保留的最大文本上下文 token 数；`-1` 使用内部默认值 |
| `-ml, --max-len N` | `0` | 每段最大字符数；`-ml 1` 常用于词级切分实验 |
| `-sow, --split-on-word` | 关闭 | 尽量在词边界切分，而不是 token 边界 |
| `-ac, --audio-ctx N` | `0` | 音频上下文长度；`0` 表示完整默认上下文，通常不要改小 |
| `--prompt TEXT` | 空 | 初始提示词，可提供专有名词、语言风格或上文 |
| `--carry-initial-prompt` | 关闭 | 每个内部窗口都携带初始提示词，长音频术语一致性可能更好 |

#### 解码质量

| 参数 | CLI 默认值 | 含义与建议 |
|---|---:|---|
| `-bo, --best-of N` | `5` | 贪心采样保留的候选数；更大更慢 |
| `-bs, --beam-size N` | `5` | 大于 1 时使用 beam search；更大通常更慢 |
| `-tp, --temperature N` | `0.0` | 初始采样温度；确定性转写通常从 0 开始 |
| `-tpi, --temperature-inc N` | `0.2` | 解码失败时逐级提高温度的步长 |
| `-nf, --no-fallback` | 关闭 | 禁用温度回退，即不再逐级提高温度 |
| `-et, --entropy-thold N` | `2.40` | 解码失败判定的熵阈值；高级参数，通常保留默认 |
| `-lpt, --logprob-thold N` | `-1.00` | 解码失败判定的平均 log probability 阈值 |
| `-nth, --no-speech-thold N` | `0.60` | 无语音判断阈值 |
| `-sns, --suppress-nst` | 关闭 | 抑制非语音 token，如部分音效标记 |
| `--suppress-regex REGEX` | 空 | 抑制匹配正则表达式的 token |
| `--grammar` 等 | 空 | 用 GBNF 语法约束解码；适合受限输出，高级用法 |

#### 任务和时间戳

| 参数 | 默认值 | 含义与建议 |
|---|---:|---|
| `-tr, --translate` | 关闭 | 把输入语音翻译为英语，不是翻译成任意目标语言 |
| `-nt, --no-timestamps` | 关闭 | 不生成或打印时间戳 |
| `-wt, --word-thold N` | `0.01` | 词时间戳概率阈值 |
| `-dtw, --dtw MODEL` | 空 | 使用指定模型预设计算 DTW token 级时间戳；模型名必须匹配 |
| `-di, --diarize` | 关闭 | 基于左右声道能量估计说话人，要求双声道、每人独占声道 |
| `-tdrz, --tinydiarize` | 关闭 | 使用 tinydiarize 标记说话人切换，必须配套 `-tdrz` 模型 |

`--diarize` 不是通用的“从一条混合录音识别任意多人”功能；它主要适用于左右声道分别录制不同
说话人的音频。`--tinydiarize` 也只标记说话人切换，且当前 `large-v3-turbo` 不是 tdrz 模型。

#### 性能与日志

| 参数 | 默认值 | 含义与建议 |
|---|---:|---|
| `-t, --threads N` | `4` | 推理计算线程数；当前配置从 4 开始调优，不要默认拉满所有核心 |
| `-p, --processors N` | `1` | `whisper_full_parallel` 的并行处理器数量；通常保持 1 |
| `-pp, --print-progress` | 关闭 | 输出处理进度 |
| `-pr, --print-realtime` | 关闭 | CLI 中边生成边打印分段 |
| `-pc, --print-colors` | 关闭 | 用颜色表示置信度，适合人工观察 |
| `--print-confidence` | 关闭 | 打印置信度 |
| `-ps, --print-special` | 关闭 | 打印特殊 token |
| `-debug, --debug-mode` | 关闭 | 调试模式，可能写出中间数据，不用于日常运行 |

## 5. whisper-server：把模型作为 HTTP 服务

### 5.1 本机推荐管理方式

安装包已经把长命令封装在脚本中，日常使用优先执行：

```bash
cd "${WHISPER_INSTALL_ROOT}"

./scripts/05-server.sh start
./scripts/05-server.sh status
./scripts/05-server.sh logs
./scripts/05-server.sh stop
```

前台排障：

```bash
./scripts/05-server.sh foreground
```

脚本优先从本地 `.env` 读取端口、线程数等配置；没有 `.env` 时使用 `.env.example`。它会完整校验
Application Support 中的唯一权威模型和 FFmpeg，后台启动后等待 `/health` 返回正常。它比手工复制
完整命令更不容易漏参数。

### 5.2 当前等价的直接启动命令

```bash
"${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-server" \
  --host "${WHISPER_HOST}" \
  --port "${WHISPER_PORT}" \
  --public "${WHISPER_INSTALL_ROOT}/third_party/whisper.cpp/examples/server/public" \
  --inference-path "${WHISPER_INFERENCE_PATH}" \
  --convert \
  --language "${WHISPER_LANGUAGE}" \
  --threads "${WHISPER_THREADS}" \
  --model "${WHISPER_APP_SUPPORT_ROOT}/runtime/models/ggml-${WHISPER_MODEL}.bin"
```

模型只在服务启动时加载一次，后续请求复用它，所以 server 特别适合多个客户端反复提交短录音。

## 6. server 启动参数详解

### 6.1 HTTP 与文件处理

| 参数 | 默认值 | 作用 |
|---|---:|---|
| `--host HOST` | `127.0.0.1` | 监听地址；`0.0.0.0` 允许局域网访问 |
| `--port PORT` | `8080` | TCP 端口 |
| `--public PATH` | `examples/server/public` | 静态网页目录；目录无首页时根路径使用内置上传页 |
| `--request-path PATH` | 空 | 所有动态路由的统一前缀 |
| `--inference-path PATH` | `/inference` | 转写接口的路径 |
| `--convert` | 关闭 | 上传后调用 FFmpeg 转为 16 kHz PCM WAV，支持 m4a/mp3 等常见格式 |
| `--tmp-dir PATH` | `.` | FFmpeg 转换临时文件目录，需保证普通用户可写 |

`--request-path` 和 `--inference-path` 是拼接关系。例如：

```text
--request-path /api --inference-path /v1/audio/transcriptions
```

会得到：

```text
POST /api/v1/audio/transcriptions
GET  /api/health
POST /api/load
```

当前没有设置 `--request-path`，所以接口分别是 `/v1/audio/transcriptions`、`/health` 和
`/load`。

### 6.2 模型、计算和识别参数

server 与 CLI 共享大部分参数，包括：

- `--model`、`--threads`、`--processors`；
- `--language`、`--translate`、`--prompt`、`--carry-initial-prompt`；
- `--offset-t`、`--duration`、`--max-context`、`--max-len`、`--split-on-word`；
- `--best-of`、`--beam-size`、`--audio-ctx`；
- `--word-thold`、`--entropy-thold`、`--logprob-thold`、`--no-speech-thold`；
- `--no-timestamps`、`--suppress-nst`、`--diarize`、`--tinydiarize`；
- `--no-gpu`、`--device`、`--flash-attn`、`--no-flash-attn`；
- 全套 VAD 参数。

与 CLI 不同的默认值或行为：

- server 的 `best_of` 默认为 `2`，`beam_size` 默认为 `-1`，因此默认采用贪心策略。
- server 启动参数没有暴露 `temperature` 和 `temperature_inc`，但每次 HTTP 请求可以传。
- server 默认语言也是 `en`；本机启动脚本显式改成了 `auto`。
- server 每次请求从启动时的默认参数复制一份，再用 multipart 字段覆盖；一个请求不会永久改变
  下一次请求的识别参数。

### 6.3 VAD 参数

VAD 会先找出包含语音的片段，只把这些片段交给 Whisper。长静音录音可能显著提速，但必须另备
VAD 模型，例如 Silero VAD。

| 参数 | 默认值 | 作用 |
|---|---:|---|
| `--vad` | 关闭 | 启用 VAD |
| `-vm, --vad-model FNAME` | 空 | VAD 模型文件；只写 `--vad` 而无模型不能正常使用 |
| `-vt, --vad-threshold N` | `0.50` | 语音概率阈值；越高越严格 |
| `-vspd, --vad-min-speech-duration-ms N` | `250` | 更短的语音片段被丢弃 |
| `-vsd, --vad-min-silence-duration-ms N` | `100` | 至少多长静音才切段 |
| `-vmsd, --vad-max-speech-duration-s N` | 无上限 | 过长语音段自动切分 |
| `-vp, --vad-speech-pad-ms N` | `30` | 每个语音段前后补多少毫秒，防止切掉边缘 |
| `-vo, --vad-samples-overlap N` | `0.10` | 相邻片段重叠秒数，减少边界丢字 |

当前服务器未安装或启用 VAD，日常短语音无需为了“参数更多”而开启。若主要处理大量长静音会议
录音，再单独下载 VAD 模型并做准确率验收。

## 7. HTTP 路由与工作方式

| 方法和路径 | 用途 | 当前状态 |
|---|---|---|
| `GET /health` | 模型就绪检查 | 就绪返回 `200 {"status":"ok"}`；加载中返回 503 |
| `POST /v1/audio/transcriptions` | 上传音频并转写 | 当前主接口 |
| `OPTIONS /v1/audio/transcriptions` | 预检请求 | server 注册了该路由 |
| `POST /load` | 从服务器本地路径重载模型 | 有风险，不建议对普通客户端开放 |
| `GET /` | 内置或静态上传页 | 主要用于简单人工测试 |

重要实现特征：

1. 请求必须是 `multipart/form-data`，音频字段名必须为 `file`。
2. `curl -F` 会自动生成带 boundary 的 `Content-Type`，通常不要手写该请求头。
3. server 为单个 Whisper 模型上下文加了互斥锁。多个 HTTP 请求可以到达服务，但转写和
   `/load` 会串行占用模型；提高客户端并发不会线性提高吞吐。
4. 客户端断开连接时，推理会尽量中止，并按实现返回 499。
5. server 的读写超时在 v1.9.2 源码中固定为 600 秒，没有对应命令行参数。

## 8. 调用转写接口

### 8.1 最小请求

```bash
curl --fail --show-error \
  --form 'file=@/绝对路径/audio.m4a' \
  --form 'model=whisper-1' \
  --form 'response_format=json' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}"
```

典型响应：

```json
{"text":"转写结果"}
```

这里的 `model=whisper-1` 用于兼容 OpenAI 风格客户端。v1.9.2 的转写处理代码不读取该字段，
因此它既不会验证模型名，也不会改变服务端已经加载的 `large-v3-turbo`。

### 8.2 指定语言、提示词和温度

```bash
curl --fail --show-error \
  --form 'file=@/绝对路径/chinese.m4a' \
  --form 'language=zh' \
  --form 'prompt=Codex，OpenWhispr，whisper.cpp，Mac mini' \
  --form 'temperature=0.0' \
  --form 'temperature_inc=0.2' \
  --form 'response_format=json' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}"
```

已知语言时传 `zh`、`en` 等可避免自动检测的不确定性；混合语言或来源未知时使用 `auto`。
`prompt` 适合提供容易拼错的人名、品牌名、缩写和上下文，但它是解码提示，不是硬性词表。

### 8.3 生成字幕

```bash
curl --fail --show-error \
  --form 'file=@/绝对路径/meeting.m4a' \
  --form 'language=auto' \
  --form 'response_format=srt' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}" \
  --output meeting.srt
```

将 `srt` 改为 `vtt` 可以生成 WebVTT。

### 8.4 只处理一段音频

以下请求从 60 秒处开始，只处理 30 秒：

```bash
curl --fail --show-error \
  --form 'file=@/绝对路径/long.m4a' \
  --form 'offset_t=60000' \
  --form 'duration=30000' \
  --form 'response_format=verbose_json' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}"
```

### 8.5 翻译为英语

```bash
curl --fail --show-error \
  --form 'file=@/绝对路径/chinese.m4a' \
  --form 'language=zh' \
  --form 'translate=true' \
  --form 'response_format=json' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}"
```

Whisper 的 `translate` 任务目标固定为英语。若要翻译成其他语言，应先转写，再交给独立翻译模型。

## 9. 每次 HTTP 请求可覆盖的字段

以下字段全部作为 multipart 文本字段传递。

| 字段 | 类型/单位 | 作用 |
|---|---|---|
| `file` | 文件，必填 | 上传的音频或视频文件 |
| `language` | 字符串 | `zh`、`en`、`auto` 等 |
| `prompt` | 字符串 | 初始解码提示 |
| `carry_initial_prompt` | 布尔 | 是否在后续窗口继续携带 prompt |
| `translate` | 布尔 | 翻译为英语 |
| `detect_language` | 布尔 | 只执行语言检测；不会生成转写文本 |
| `response_format` | 枚举 | `json`、`verbose_json`、`text`、`srt`、`vtt` |
| `offset_t` | 毫秒 | 开始时间偏移 |
| `duration` | 毫秒 | 处理时长，0 表示其余全部 |
| `offset_n` | 整数 | SRT 分段编号偏移 |
| `max_context` | token 数 | 最大文本上下文 |
| `max_len` | 字符数 | 分段最大长度 |
| `split_on_word` | 布尔 | 尽量按词边界分段 |
| `best_of` | 整数 | 贪心候选数 |
| `beam_size` | 整数 | 大于 1 时使用 beam search |
| `audio_ctx` | 整数 | 音频上下文长度，通常保持 0 |
| `temperature` | 0 到 1 | 初始采样温度 |
| `temperature_inc` | 0 到 1 | 解码回退时温度增量 |
| `word_thold` | 浮点数 | 词时间戳概率阈值 |
| `entropy_thold` | 浮点数 | 解码失败熵阈值 |
| `logprob_thold` | 浮点数 | 解码失败 log probability 阈值 |
| `no_speech_thold` | 浮点数 | 无语音概率阈值 |
| `no_timestamps` | 布尔 | 禁用时间戳 |
| `token_timestamps` | 布尔 | 是否在详细 JSON 中生成 token/词时间戳 |
| `suppress_non_speech` | 布尔 | 抑制非语音 token |
| `suppress_nst` | 布尔 | 上一字段的别名 |
| `diarize` | 布尔 | 双声道说话人估计 |
| `tinydiarize` | 布尔 | tdrz 说话人切换标记，需要配套模型 |
| `vad` | 布尔 | 启用 VAD，server 启动时必须已有 VAD 模型路径 |
| `vad_threshold` | 浮点数 | VAD 语音阈值 |
| `vad_min_speech_duration_ms` | 毫秒 | 最短语音片段 |
| `vad_min_silence_duration_ms` | 毫秒 | 切段所需最短静音 |
| `vad_max_speech_duration_s` | 秒 | 单段最长语音 |
| `vad_speech_pad_ms` | 毫秒 | 语音段前后填充 |
| `vad_samples_overlap` | 秒 | 相邻段重叠 |
| `no_language_probabilities` | 布尔 | `verbose_json` 中不计算语言概率，可减少额外开销 |
| `debug_mode` | 布尔 | 调试模式 |

布尔解析只有 `true`、`1`、`yes`、`y` 会被视为真；其他字符串均为假。建议统一传
`true` 或 `false`。

## 10. 响应格式

### `json`

最适合普通应用，只返回合并后的文本：

```json
{"text":"..."}
```

### `verbose_json`

适合字幕编辑、时间轴分析或调试。主要字段包括：

- `task`、`language`、`duration`、`text`；
- `segments[]`，每段包含 `id`、`text`、`start`、`end`；
- token、词文本、概率、可选词级时间戳；
- 默认还会计算检测语言及语言概率。

语言概率计算有额外开销，不需要时传：

```text
no_language_probabilities=true
```

### `text`

返回纯转写内容。v1.9.2 实现的 Content-Type 是 `text/html; charset=utf-8`，尽管内容本质上是
普通文本。

### `srt` / `vtt`

直接返回字幕文件内容，分别适合通用播放器和 Web 字幕。

## 11. `/load` 动态换模型

请求示例：

```bash
curl --fail --show-error \
  --form 'model=/服务器上的绝对路径/ggml-model.bin' \
  http://127.0.0.1:8080/load
```

这里的 `model` 是**服务器本地文件路径**，不是上传模型文件。调用时服务会释放当前模型并加载
指定模型，而且 `/load` 与推理共用同一把锁。

不建议把 `/load` 暴露给不可信客户端：当前 server 没有认证，任何能访问该路由的人都可以尝试
让进程加载服务器上某个已存在的路径；如果新模型初始化失败，v1.9.2 的实现可能直接退出进程。
本机确需换模型时，应同时更新固定的模型名、size 和 SHA，运行 `03-download-model.sh` 把新模型放到
唯一权威目录，再依次验证 CLI、direct 和 on-demand；不要让 `/load` 指向仓库里的临时模型路径。

## 12. OpenAI API 兼容性的边界

这个 server 是“OpenAI 风格”的轻量接口，不是完整 OpenAI API 实现：

- 可以把转写路径设置成 `/v1/audio/transcriptions`；
- 使用 multipart `file` 和 `response_format`，`json` 响应含 `text`；
- 接受但忽略转写请求中的 `model=whisper-1`；
- 没有 `/v1/models`；
- 没有 API Key 验证，也不会验证 `Authorization`；
- 没有 TLS、用户隔离、配额或速率限制；
- 没有独立的 `/v1/audio/translations` 路由，翻译通过 `translate=true`；
- 不提供 token 流式 HTTP 响应；
- `verbose_json` 尽量接近 OpenAI Whisper Python 格式，但并非字段完全一致。

因此，能自定义“OpenAI Base URL”的客户端通常可以接入；强依赖模型列表、鉴权探测、固定路由
或完整 OpenAI 响应结构的客户端可能需要额外代理层。

OpenWhispr 自托管地址应填写：

```text
http://${WHISPER_LAN_HOST}:${WHISPER_PORT}/v1
```

客户端会追加 `/audio/transcriptions`。若只填 `http://${WHISPER_LAN_HOST}:${WHISPER_PORT}`，旧版客户端会请求
不存在的 `/audio/transcriptions` 并得到 404。

## 13. 性能和准确率调优建议

建议一次只改一个参数，并使用相同的中英文真实录音对比耗时和错误率。

1. **先固定模型。** 当前优先保留 `large-v3-turbo`；只有资源或延迟不满足时再换模型。
2. **已知语言就明确指定。** 固定中文使用 `language=zh`；来源混合时才使用 `auto`。
3. **专有名词用 prompt。** 提供少量相关词汇，避免把整篇预期答案塞进 prompt。
4. **线程从 4 开始。** 当前主要依靠 Metal；CPU 线程不是越多越快，需实测 4、6、8。
5. **默认贪心通常足够。** 提高 `beam_size` 或 `best_of` 会增加计算量，不保证所有音频更准。
6. **长静音录音再考虑 VAD。** VAD 需要独立模型，也可能切掉过短或过轻的语音。
7. **普通客户端用 JSON。** 不需要时间轴时避免 `verbose_json` 和语言概率计算。
8. **不要用并发压单进程。** 当前模型推理由互斥锁串行化；吞吐瓶颈需要多进程或上层队列，
   但多进程会重复占用模型内存和 GPU 资源，必须单独压测。

## 14. v1.9.2 server 参数陷阱

以下结论来自当前 tag 的 `examples/server/server.cpp`，不是对未来版本的保证：

- `--no-fallback` 会被解析，但 server 推理代码仍直接使用 `temperature_inc`，没有像 CLI 那样把
  它置零；不要依赖该启动选项，若需要禁用回退，在请求里传 `temperature_inc=0`。
- `--print-realtime` 会被解析，但推理参数随后被强制设置为不实时打印，因此 server 不提供真正的
  流式输出。
- `--detect-language` 的帮助文字沿用了 CLI 的“检测后退出”。server 进程本身不会退出，但当前
  请求只完成语言检测，随后返回空转写文本；普通转写应使用 `language=auto`，不要传
  `detect_language=true`。
- `--public` 只控制静态网页目录，不是 HTTP URL 前缀；路由前缀由 `--request-path` 控制。
- server 参数中的 `--diarize` 与 `--tinydiarize` 不能同时使用。

## 15. 安全和部署边界

官方 server README 明确提醒：示例服务接收文件上传并可调用 FFmpeg，不应以管理员权限运行，
应在隔离、可信的环境中使用。

本机部署应继续遵守：

- 只在可信局域网使用，不做公网端口转发；
- 以普通用户运行，不使用 `sudo whisper-server`；
- 保持 FFmpeg 和 whisper.cpp 更新，但升级前先在独立目录验收；
- 不把 `/load` 暴露给不可信用户；
- 如需公网或跨团队使用，在前面增加带 TLS、认证、上传大小限制、速率限制和日志审计的网关；
- 不把当前裸 server 当成多租户生产 API。

## 16. 常见故障

### `404 File Not Found (/audio/transcriptions)`

客户端缺少 `/v1`。OpenWhispr 的 Base URL 填：

```text
http://${WHISPER_LAN_HOST}:${WHISPER_PORT}/v1
```

### `/health` 正常，但转写报 400

确认请求使用 multipart，且音频字段名是 `file`：

```bash
curl -F 'file=@/absolute/path/audio.m4a' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}"
```

### 上传 m4a 后音频读取失败

确认 server 启动时有 `--convert`，并确认 `ffmpeg` 在服务进程的 `PATH` 中：

```bash
command -v ffmpeg
./scripts/05-server.sh logs
```

### 返回 JSON 但 `text` 为空

- 确认录音不是静音，声道和音量正常；
- 显式尝试 `language=zh` 或正确语言；
- 先用 CLI 转成标准 WAV 做对照；
- 查看 server 日志是否识别到了错误语言；
- 不要一开始同时修改温度、VAD、beam 和阈值。

### 请求长时间等待

- 另一个请求可能正持有模型互斥锁；
- 大文件仍在 FFmpeg 转换或推理；
- 查看日志和当前连接，不要仅靠增加客户端超时掩盖问题；
- v1.9.2 server 内部读写超时为 600 秒。

### `/health` 返回 503

模型仍在加载。等待并查看：

```bash
./scripts/05-server.sh logs
```

## 17. 推荐日常流程

```bash
# 1. 启动并检查
cd "${WHISPER_INSTALL_ROOT}"
./scripts/05-server.sh start
./scripts/05-server.sh status

# 2. 从客户端健康检查
curl --fail "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}/health"

# 3. 提交转写
curl --fail --show-error \
  --form 'file=@/绝对路径/audio.m4a' \
  --form 'language=auto' \
  --form 'response_format=json' \
  "http://${WHISPER_LAN_HOST}:${WHISPER_PORT}${WHISPER_INFERENCE_PATH}"

# 4. 出错时看日志
./scripts/05-server.sh logs

# 5. 不再使用时停止
./scripts/05-server.sh stop
```

## 18. 依据与继续阅读

- [whisper.cpp v1.9.2 主 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/README.md)
- [whisper-server v1.9.2 README](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/README.md)
- [whisper-server v1.9.2 源码](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/examples/server/server.cpp)
- [v1.9.2 模型说明](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md)
- [whisper.cpp v1.9.2 Release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2)
- 本项目的 [README.md](../README.md)

参数的最终依据始终是当前二进制帮助和对应 tag 的源码：

```bash
"${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-cli" --help
"${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-server" --help
```
