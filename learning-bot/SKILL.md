---
name: learning-bot
description: |
  Learning Bot 的入口 / 启动 skill。调用本技能即可"开启 Learning Bot"：它会把一组**预设问题**推荐
  给用户，每条预设问题对应一个在 Intel AIPC 上本地运行的 aipc-skill（ASR、TTS、实时翻译、OCR(NPU)、
  MinerU 文档解析、PaddleOCR-VL-1.5 结构化解析(GPU)、文生图、图生图、文生视频、图片超分放大、
  YOLO26 物体检测、截图问答、启蒙学习助手、电脑自动化、显存上限调整、爱奇艺视频、游戏路书）。
  这 17 个 skill 是**原子能力**：本技能会先分析用户需求能否以它们为基础搭出来 —— 单个能力能做就
  直接调用；需要多个能力才能做的，就把它们按数据流顺序**组合成一条链**（如 mineru→tts 做有声书、
  asr→realtime-translator 做实时字幕、ocr→tts 朗读图片文字）。三个开发类 skill
  （openvino-environment-management 配环境、openvino-content-fetch 找 notebook / 下载模型、
  openvino-pipeline-optimization 组装 / 优化 / 部署流水线）是**辅助**：只在链条缺环境、缺模型、
  需要服务化，或某一段能力这 17 个原子覆盖不到时才参与，由那一段单独开发后接回链条。
  只有当需求的**产出物本身就是开发资产**（环境 / notebook / 模型文件 / 量化 IR / 性能报告）时，
  才直接交给开发类 skill 从零开发。
  当用户想启动 / 打开 learning bot、想知道"你能做什么 / 有哪些功能"、或提出上述任一本地推理需求时调用
  本技能。触发词：start learning bot、open learning bot、启动 / 开启 learning bot、你能做什么、
  有哪些功能、推荐一些能力、语音转文字、文字转语音、实时翻译、OCR、识别文字、解析 PDF、文生图、
  图生图、视频生成、图片超分、目标检测、截图问答、启蒙学习、电脑自动化、显存上限调整、看电影 / 爱奇艺、
  游戏路书。
  需要 Intel AIPC (Windows)。
---

# Learning Bot —— 入口 / 启动 skill

## 如何调用本技能

入口脚本：`learning-bot/scripts/run.ps1`（也可用同目录的 `run.cmd`）。

**照抄下面这一行的形式，不要简写成 `run.ps1 -Menu`** —— PowerShell 不会从当前目录执行裸文件名，
而且脚本在 `scripts/` 子目录下，简写形式必然报 `not recognized`：

```powershell
# <REPO> = 本仓库根目录，例如 D:\learning-bot-skills
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -Menu
```

| 约定 | 说明 |
|---|---|
| 工作目录 | 任意 —— 只要 `-File` 后面是正确的绝对路径 |
| 退出码 | `0` = 成功；`1` = 失败（含未知参数、python 缺失） |
| 判断成败 | **只看 `[SKILL_RESULT]` 里的 `status=`**，不要凭「有输出」就断定成功 |
| 参数写法 | 单连字符 + 完整参数名（`-Menu` / `-Route` / `-Resolve` / `-Capacity` / `-CanRun`），不要用缩写 |
| 未知参数 | 返回 `status=error`、`reason=unknown-argument` 并退出 1，**不会**静默忽略 |

## 本机资源与模型可行性

推荐模型前先确认本机装得下 —— 8GB 显存跑不了 15B 模型，与其让用户下完几个 GB 才发现 OOM，
不如先算一笔账。

```powershell
# 探测本机预算（会调 OpenVINO，首次较慢，结果缓存到 ~/.openvino/capacity.json）
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -Capacity

# 判定某个模型跑不跑得动（参数量/精度可从 model id 自动解析）
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -CanRun "Qwen2.5-7B-Instruct-INT4-OV"
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -CanRun "某模型" -Params 15 -Precision INT4
```

`-Capacity` 输出 `action=capacity`；`-CanRun` 输出 `action=can-run`，含 `fits=true|false|unknown`、
`need_gb`、`budget_gb`，超预算时还有 `alternatives`。

**三件最容易搞错的事：**

1. **iGPU 的显存和系统内存是同一块。** `gpu_type=integrated` / `shared_with_ram=true` 时，
   `gpu_budget_gb` 和 `free_ram_gb` **不能相加**；`usable_budget_gb` 已经取过两者的较小值，
   直接用它就行。
2. **默认按 INT4 估算**（AIPC 部署的常态）。model id 里写了 `-FP16-` 之类才会按那个精度算。
   系数在 [scripts/model_sizing.json](scripts/model_sizing.json)，可按实测调整。
3. **`source=estimate` 时结论只是参考** —— 那表示机器上没装 OpenVINO，预算是从系统内存粗估的。
   `fits=unknown` 表示没探测过或解析不出参数量，**不要**把它当成「能跑」。

`fits=false` **不代表禁止使用** —— 估算刻意偏保守。要如实把 `need_gb` / `budget_gb` /
`alternatives` 告诉用户，由用户决定，不要擅自替他放弃。

---

本技能是 Learning Bot 的**入口**。调用它 = "开启 Learning Bot"：向用户推荐一组预设问题，并根据用户
的问题把请求路由到正确的下游 skill。它自己不做推理，而是负责**推荐 + 路由 + 安装**：

1. **推荐（Menu）** —— 被调用时，把下面 17 条预设问题推荐给用户。每条预设问题都对应一个在本机
   （Intel AIPC）离线运行的 aipc-skill。
2. **路由（Route）** —— 见下面的「路由判断顺序」。
3. **解析（Resolve）** —— 把内部 key 解析成上架后的官方 skill 名；这些 skill 已上架，宿主按名字直接调用，不需要下载。
4. **安装（Install、备用方案）** —— **宿主上找不到该 skill 时**，从 AI PC Skills release 下载技能包并解压到本地。

> 路由脚本给出的是**建议**，不是硬性判决。最终由 agent 结合上下文决定调用哪个 skill。

---

## 备用方案：skill 没预置时从 release 下载

正常路径是「`-Resolve <key>` 拿到 `skill_name` → 宿主按名字调用」。但如果宿主上**根本没预置**
这个 skill（按名字调不到 / 找不到该能力），不要就此放弃、也不要改走云端 —— 改用备用方案：

```powershell
# 从 AI PC Skills release 1.0.9 下载并解压技能包（默认装到 ~/.openvino/aipc-skills）
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -Install asr

# 指定目录 / 强制重装
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -Install asr -OutDir D:\aipc-skills -Force
```

下载地址由 registry 的 `release.base_url` + 该 skill 的 `zip` 字段拼成，发布页：
https://github.com/makejiang/aipc-skills/releases/tag/1.0.9
。`-Resolve` 也会把完整地址放在 `fallback_url=` 里，方便你提前判断。

约定：

1. **先 Resolve、后 Install** —— 能按名字调就不要下载；`-Install` 只是宿主未预置时的兵底。
2. `-Install` 是本技能里**唯一联网**的 preset 相关命令（`-Capacity` 会调硬件探测）；
   `-Menu` / `-Route` / `-Resolve` / `-Questions` 仍然全程离线。
3. 下载过程会打印以 `技能包下载中` 开头的进度行，**同样要实时展示给用户**。
4. 已安装时返回 `installed=already` 并跳过下载；需要重装加 `-Force`。
5. 失败时返回 `status=error` 并给出 `url` 与 `install_dir`，让用户可以手动下载解压 —— **绝不伪造成功**。
6. 装完后按返回的 `entry=`（解压出来的 `scripts\run.ps1`）调用该 skill；
   它首次运行依然会下载模型，适用下面的进度条强制要求。

---

## 强制要求：模型下载必须展示进度条

17 个本地能力里，除 `vram` 和 `iqiyi` 外均需要**首次下载模型**（几百 MB 到 22 GB 不等）。
`-Resolve <key>` 会把这件事告诉你：

| 字段 | 含义 |
|---|---|
| `model_download=true` | 该 skill 首次调用会从 ModelScope 拉模型 |
| `progress_required=true` | **必须**把下载进度展示给用户 |

被调用的 skill 会在 stdout 上持续打印以 `模型下载中` 开头的进度行，例如：

```
模型下载中 [████████░░░░░░░░░░░░]  42.3% | 1.1 GB/2.6 GB | 11.4 MB/s | 剩余约 2分10秒 | Qwen/Qwen3-ASR
```

硬性约定（不可省略）：

1. **每出现一行新进度就立即转达给用户**，包含百分比、已下载/总大小、速度、剩余时间、当前模型。
   宿主 UI 支持进度条控件时直接渲染成进度条，不支持则原样输出这一行。
2. **退出码 3 = 下载未完成**，不是失败。按提示重新调用 `scripts\run.ps1 --continue`，
   循环直到出现正常结果（大模型可能需要 4–8 次续跑）。
3. **禁止长时间静默等待**，也禁止因为「要下载很久」就改走云端 API 或其他 skill。
4. 首次下载前先把**大致体积和耗时**告知用户；`scene-recognition` 这类 ~22 GB 的大下载要先征得同意。
5. 组合链（`targets=a,b,c`）上每一段都适用以上规则，要说清楚当前在下载哪一段的模型。

`model_download=false` 的能力（`vram` / `iqiyi`）没有模型下载，不要凭空编一个进度条。

---

## 核心原则：17 个本地能力是**原子能力**，优先拿它们拼装

这 17 个 skill 不是一张「命中就调、没命中就算了」的查找表，而是一组**可以串起来用的积木**。
面对一个需求，**先分析它能不能用这些原子能力（单个或组合）搭出来**，能搭就搭；三个开发类 skill
（ENV / FETCH / PIPE）是**辅助**，负责补环境、找模型、做服务化，而不是一没命中预设就整个接管、
从零开发。

### 先看产出物是什么 —— 这决定了归属

| 产出物 | 归属 | scope |
|---|---|---|
| 本地推理结果（文字 / 语音 / 图 / 视频 / 检测框） | 预设原子能力 | `preset` |
| 可运行的**应用**（= 多个推理结果串起来） | 预设原子能力**组合** | `compose` |
| **散文文档**（PRD / 培训材料 / 学习路径） | **agent 自己的写作能力**，skill 只提供素材 | `synthesize` |
| 开发资产（环境 / notebook / 模型文件 / 量化 IR / 性能报告） | 开发类 skill | `dev` |

> 物料上四个应用场景的对应关系：**APP Build → `compose`**；
> **PRD Build / Customize Training / Learning Path Planning → `synthesize`**。
> 后三者**不是** 17 个原子能力之外的额外 skill —— 它们没有可安装的 skill、
> 也没有 `[SKILL_RESULT]` 可产出，真正干活的是你的写作能力。

### 路由判断顺序（严格按此顺序）

| # | 判断 | 结果 |
|---|---|---|
| 1 | 提到非 Intel 硬件（Mac / Apple Silicon 等）？ | `clarify` —— 先确认硬件平台 |
| 2 | 要的是**文档**（PRD / 培训材料 / 学习路径）？ | `synthesize` —— 见下节 |
| 3 | 需求的**产出物**是不是开发资产（环境 / notebook / 教程 / 模型文件 / 量化 IR / 性能报告）？ | `dev` —— 这类拿原子能力当不了基础 |
| 4 | 能不能用**多个**原子能力**组合**做出来？ | `compose` —— 返回有序链 `targets` |
| 5 | 能不能用**一个**原子能力做出来？ | `preset` |
| 6 | 以上都不行 | `dev` / `clarify` |

**关键点：第 4 步排在第 5 步之前，第 4、5 步都排在「转交开发类 skill」之前。**
只有第 3 步（产出物本身就是开发资产）和第 6 步才允许直接走开发类 skill。

**第 2 步为什么必须排这么靠前**：「给一个端侧会议纪要总结功能写个 PRD」里的「会议纪要」会命中
组合配方，如果不先判定内容合成，就会被路由成 `preset/asr` —— 用户要的是一份文档，却跑去装
ASR skill 做推理。

### `synthesize` 的处理约定

命中后返回 `scope=synthesize`、`target=openvino-content-fetch`、
`deliverable=prd|training|learning-path`，`targets=` 为空（没有可执行的链条）。做法是：

1. 用 `openvino-content-fetch` 抓**真实**的 OpenVINO notebook / 示例当素材（grounding）。
2. **正文由你自己写** —— 结构化 PRD、培训讲解材料、循序渐进的学习路径。
3. **标注来源** notebook / 示例，不要凭空编造。
4. **不要**安装任何 preset skill、**不要**搭环境、**不要**下载模型、**不要**部署服务 ——
   除非用户明确另外要求。这些是内容交付物，不是可运行的 demo。

### 链条上有缺口怎么办 —— `gaps=`

如果需求里有一段是 17 个原子能力覆盖不到的（声纹识别、人脸识别、图像分割、深度估计、
姿态估计、人声分离、视频问答），**不要因此放弃整条链**：

- 能被原子能力覆盖的阶段 → **照常用预设原子能力**
- 覆盖不到的阶段 → 出现在 `gaps=` 里，**参考 `openvino-content-fetch`（找模型）和
  `openvino-pipeline-optimization`（接进流水线）单独开发这一段**，做完再接回链条

例：「把这段录音转成文字，并区分是谁在说话」
→ `targets=asr`（转文字用现成原子能力）+ `gaps=speaker-id`（说话人分离需要单独开发）。

### 辅助字段 `assist=`

即使是 `preset` / `compose`，也可能需要开发类 skill 打配合：

| 用户提到 | `assist` |
|---|---|
| 部署 / 服务 / 常驻 / 流水线 / 优化 / 加速 | `openvino-pipeline-optimization` |
| 没装 / 装不上 / 环境 / 第一次用 | `openvino-environment-management` |
| 缺模型 / 没有模型 / 换个模型 | `openvino-content-fetch` |

例：「把 whisper→LLM→TTS 组成流水线并部署成服务」
→ `scope=compose`、`targets=asr,tts`、`assist=openvino-pipeline-optimization`。
**主体仍然是预设原子能力**，PIPE 只负责把它变成常驻服务。

### 组合执行约定

拿到 `targets=a,b,c` 后，agent 按顺序逐个执行，**不要期待脚本自动串联**：

1. 对每个 key 依次 `-Resolve <key>` 取到 skill 名，再按该名字调用。
2. 把上一步的产物作为下一步的输入（各阶段的输入 / 输出类型见 registry 的 `io` 字段）。
3. **每一步都要解析 `[SKILL_RESULT]` 的 `status=`**，失败就停下并如实报告，不要硬着头皮往下走。
4. 某一步的 `-Resolve` 返回 `progress_required=true` 时，该 skill 首次调用会下载模型 ——
   **必须实时展示它的下载进度条**（见上文「强制要求：模型下载必须展示进度条」）。
5. `gaps=` 里的阶段没有现成 skill，按 FETCH → PIPE 的路子单独做，做完再接回链条。

### 已知组合配方

维护在 [`scripts/skills_registry.json`](scripts/skills_registry.json) 的 `combos` 里（与路由同源）：

| 配方 | 链条 |
|---|---|
| 实时字幕 / 会议助手 | `asr → realtime-translator` |
| 会议纪要 | `asr` → 由 agent 直接总结 |
| 文档转有声书 | `mineru → tts` |
| 图片文字朗读 | `ocr-npu → tts` |
| 看屏幕并自动操作 | `screenshot-qa → computer-use` |
| 带配音的视频 | `txt2video → tts` |

配方表是白名单，不追求穷尽；没列进去的组合由「命中多个原子能力」自动按 `flow_order` 排序兜住。

---

## 预设问题（推荐给用户 · 17 个本地能力）

调用本技能时，把这些问题原样推荐给用户（"你可以直接问我下面这些……"）。用户问到其中任意一条，
就调用对应 skill。

**这 17 个 skill 已经上架**（Intel AI PC Skills release 1.0.9），按 `skill 名` 直接调用即可。
`key` 只是仓库内部的稳定标识（路由、关键词、组合配方都用它），对外调用请用 `skill 名`。
宿主上找不到某个 skill 时，用 `-Install <key>` 走上文的**备用下载方案**。
「首次下载模型」一列标 ✅ 的能力，第一次调用时**必须**给用户展示下载进度条。

| # | 预设问题（推荐话术） | skill 名（调用用） | key（内部） | 首次下载模型 |
|---|---|---|---|---|
| 1 | "帮我把这段录音/语音转成文字。" | `Local ASR` | `asr` | ✅ |
| 2 | "把这段文字读出来，生成一段语音。" | `Local TTS` | `tts` | ✅ |
| 3 | "根据这段描述生成一张图片。" | `Local T2I` | `txt2img` | ✅ |
| 4 | "帮我自动操作电脑完成某个任务。" | `Local computer use` | `computer-use` | ✅ |
| 5 | "识别这张图片里的文字。" | `Local OCR on NPU` | `ocr-npu` | ✅ |
| 6 | "帮我解析这个 PDF，转成 Markdown / 结构化文本。" | `local-mineru` | `mineru` | ✅ |
| 7 | "帮我截个屏，然后回答关于屏幕内容的问题。" | `local-screenshot-qa` | `screenshot-qa` | ✅ |
| 8 | "帮我调整集成显卡的共享显存上限。" | `local-vram` | `vram` | — |
| 9 | "基于这张图重绘 / 修改一张新图。" | `local-img2img` | `img2img` | ✅ |
| 10 | "帮我实时翻译这段对话/语音。" | `local-realtime-translator` | `realtime-translator` | ✅ |
| 11 | "根据这段描述生成一段视频。" | `local-txt2video` | `txt2video` | ✅ |
| 12 | "帮我把这份发票/表单/报表解析成结构化数据。" | `local-ocr-gpu` | `paddleocr-vl` | ✅ |
| 13 | "检测这张图片里有哪些物体。" | `local-yolo26` | `yolo26` | ✅ |
| 14 | "把这张图片放大 4 倍 / 变清晰。" | `local-sr` | `sr` | ✅ |
| 15 | "打开启蒙学习助手，对着摄像头出示卡片就能语音讲解。" | `local-scene-recognition` | `scene-recognition` | ✅（约 22 GB） |
| 16 | "帮我搜一部电影并播放。" | `iqiyi` | `iqiyi` | — |
| 17 | "帮我做一个游戏实时攻略助手。" | `game-assistant-walkthrough` | `game-guide` | ✅ |

几个容易搞混的点：

- **OCR 有两个设备版本，分工不同**：`Local OCR on NPU`（`ocr-npu`）用 NPU 做纯文字提取，快、省电；
  `local-ocr-gpu`（`paddleocr-vl`，即 PaddleOCR-VL-1.5）用 GPU 做**保留版面的结构化提取**
  （发票 / 表单 / 表格 → JSON / Markdown，可接 document-to-data / document-to-code）。
- **文档解析也有两个**：`local-mineru` 做通用 PDF/图片转 Markdown；`local-ocr-gpu` 做版面保留的
  结构化提取。两者同属一个流水线阶段，**不要串成一条链**。
- **`local-txt2video` 就是原清单里的 LightX2V 位**，覆盖文生视频；图生视频与图像编辑请配合
  `local-img2img`。
- **`local-vram` 是"调整"共享显存上限**，不是只读查看。想知道本机还剩多少可用预算，
  用本技能的 `-Capacity`（见上文「本机资源与模型可行性」）。
- **`iqiyi` 是唯一一个走网络内容接口的能力**（爱奇艺搜索 / 推荐 / 播控），不做本地推理、
  也没有模型下载。
- **原清单里的 `Desktop Pet` 已不在 1.0.9 上架列表中**，不要再推荐它。

用 `-Resolve <key>` 可以把内部 key 解析成上面的 skill 名：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\learning-bot\scripts\run.ps1" -Resolve mineru
# -> skill_name=local-mineru
#    model_download=true
#    progress_required=true
```

清单统一维护在 [`scripts/skills_registry.json`](scripts/skills_registry.json)。

---

## 超出预设范围 → 路由到开发类 skill

当用户的需求不是上面 17 个"开箱即用的本地能力"，而是**开发 / 构建**类需求时，改为路由到本仓库的三个
开发类 skill（见 [../README.md](../README.md)）：

| skill | 何时用 |
|---|---|
| [`openvino-environment-management`](../openvino-environment-management/) (ENV) | 需要在 Intel AIPC 上搭建 / 配置 OpenVINO 开发环境 |
| [`openvino-content-fetch`](../openvino-content-fetch/) (FETCH) | 找 notebook / 教程 / 示例 / 文章，或搜索 / 下载模型与预转换 IR |
| [`openvino-pipeline-optimization`](../openvino-pipeline-optimization/) (PIPE) | 把多个模型组装成流水线、优化设备/精度、做基准测试或部署为服务 |

判断优先级见上面的「路由判断顺序」：**预设组合 → 预设单点 → 开发类 skill → 追问澄清**。

只有当用户的**产出物本身就是开发资产**时才直接走开发类 skill —— 开发意图词为
"下载模型 / 找模型 / 搭环境 / benchmark / 找瓶颈 / 量化 / notebook / 教程 / 学习路径"。
即使句子里出现了某个模态词也一样（例如 "下载 ASR 模型" 是 FETCH 的活，不是 `asr`）。

> **注意"部署 / 流水线 / 服务化"不在这个列表里。** 「把 asr→llm→tts 组成流水线并部署成服务」
> 是能用预设原子能力搭出主体的，应当走 `compose` 并把 PIPE 放进 `assist=`，
> 而不是整个交给 PIPE 从零开发。

---

## 参数

| 参数 | 说明 |
|---|---|
| -Menu | 打印推荐给用户的预设问题（默认动作 = 启动 Learning Bot） |
| -Questions \<type\> | 输出准备好的问题：`preset` / `preflight` / `clarify` / `all`（`[SKILL_QUESTIONS]` 契约，离线） |
| -Route "\<text\>" | 对一句用户输入给出路由建议（preset / dev / clarify） |
| -Resolve \<key\> | 把内部 key 解析成上架后的 skill 名（宿主按该名字调用）；离线 |
| -Install \<key\> | \[备用方案\] 宿主未预置该 skill 时，从 release 下载并解压技能包（**唯一联网命令**） |
| -OutDir | `-Install` 的解压目录；默认 `~/.openvino/aipc-skills` |
| -Force | `-Install` 时即使已存在也重新下载 |

下面用 `$RUN` 代表入口脚本的绝对路径，实际调用时替换掉：

```powershell
$RUN = "<REPO>\learning-bot\scripts\run.ps1"    # 例如 D:\learning-bot-skills\learning-bot\scripts\run.ps1

# 启动 Learning Bot：推荐预设问题
powershell -NoProfile -ExecutionPolicy Bypass -File $RUN -Menu

# 输出准备好的问题（前置条件多选 / 澄清 / 全部）
powershell -NoProfile -ExecutionPolicy Bypass -File $RUN -Questions preflight

# 对用户输入做路由（返回 preset / dev / clarify 建议）
powershell -NoProfile -ExecutionPolicy Bypass -File $RUN -Route "帮我把这段录音转成文字"

# 把 key 解析成上架后的 skill 名（宿主按该名字调用；不会下载任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File $RUN -Resolve asr

# 备用方案：宿主没预置该 skill 时，从 release 下载并解压技能包
powershell -NoProfile -ExecutionPolicy Bypass -File $RUN -Install asr
```

---

## 准备好的问题（Prepared Questions）

除了 `-Menu`（推荐预设问题），本技能还能输出统一契约的**准备好的问题**，供 agent 渲染成交互式清单
（离线、无需网络）：

- **preset** —— 17 条本地能力推荐（**从 [`scripts/skills_registry.json`](scripts/skills_registry.json) 单一来源生成**，与 `-Menu` 同源）。
- **preflight** —— 前置条件多选：是否 Intel AIPC、能否直连、要本地能力还是开发。
- **clarify** —— 追问用户想用哪一类能力（语音/图像/文档/自动化/开发）。

```powershell
run.ps1 -Questions preset      # = 菜单，但走统一 [SKILL_QUESTIONS] 契约
run.ps1 -Questions preflight   # 前置条件多选
run.ps1 -Questions clarify     # 澄清模态
run.ps1 -Questions all         # 以上全部
```

### `[SKILL_QUESTIONS]` 契约
```
[SKILL_QUESTIONS]
skill=learning-bot
type=preset|preflight|clarify|all
count=<问题块数>
data=<紧凑 JSON 数组；每个块 {type,id,prompt,multiselect,options:[{key,label,example?,exclusive?,on_missing?}]}>
[/SKILL_QUESTIONS]
```

preflight/clarify 的题目定义在 [`scripts/questions.json`](scripts/questions.json)；preset 由
`learning_bot.py` 从 registry 动态生成。`on_missing` 为 `self:dev-route` 表示应转到开发类 skill，
`self:-China` 表示改用国内镜像。

## [SKILL_RESULT] 契约

### 推荐（menu）

```
[SKILL_RESULT]
status=ok
action=menu
count=17
data=[{"key":..,"name":..,"question":..,"model_download":true|false}, ...]
[/SKILL_RESULT]
```

### 路由（route）

```
[SKILL_RESULT]
status=ok
action=route
matched=true|false
scope=preset|compose|synthesize|dev|clarify
target=<单个 key；compose 时为链首；synthesize 时固定为 openvino-content-fetch；clarify 时为空>
targets=<有序逗号分隔的完整链条；synthesize/dev/clarify 时为空>
deliverable=<prd|training|learning-path；仅 synthesize 时非空>
assist=<逗号分隔的辅助 dev skill；可为空>
gaps=<逗号分隔的缺口 id：预设原子能力覆盖不到、需要单独开发的阶段；可为空>
reason=<归类理由>
[/SKILL_RESULT]
```

`target=` 保留为单个值，只读它的老解析方不会出错；要拿完整链条请读 `targets=`。
`gaps=` 非空表示这条链有一段没有现成 skill —— **其余阶段仍然照常用预设原子能力**，
只有缺口那段需要参考 FETCH / PIPE 单独开发。

### 解析（resolve）

```
[SKILL_RESULT]
status=ok|error
action=resolve
skill=<key>
skill_name=<上架后的官方 skill 名，宿主按它调用>
name_cn=<中文名>
model_download=true|false      # 首次调用是否会下载模型
progress_required=true|false   # true 时必须向用户实时展示下载进度条
fallback_url=<宿主没预置时可以下载的技能包地址>
progress_note=<progress_required=true 时给出的具体做法>
fallback_note=<怎么走备用安装路径>
note=already published; invoke it by skill_name (no skill-package download needed)
[/SKILL_RESULT]
```

key 不存在时返回 `status=error` 并列出可选 key —— **绝不伪造成功**。

### 安装（install、备用方案）

```
[SKILL_RESULT]
status=ok|error
action=install
skill=<key>
skill_name=<官方 skill 名>
installed=downloaded|already
install_dir=<解压到的本地目录>
entry=<解压出来的 scripts\run.ps1 绝对路径，后续按它调用>
url=<技能包下载地址>
model_download=true|false
progress_required=true|false
[/SKILL_RESULT]
```

下载失败（无网络 / 404）时返回 `status=error`，并把 `url` 和 `install_dir` 一并给出，方便用户
手动下载 zip 后解压 —— **绝不伪造成功**。

---

## agent 使用约定

- 被调用时先输出预设问题清单（`-Menu`），让用户知道能问什么。
- 拿到用户具体请求后用 `-Route` 得到建议，再据此决定：`preset` → `-Resolve <key>` 取名字并调用该 skill；
  `dev` → 转交对应开发类 skill；`clarify` → 先追问。
- 解析每个 `[SKILL_RESULT]` 的 `status`；安装/调用失败不要谎报成功。
- 按 `skill_name` 调不到、宿主没预置该 skill 时，改走备用方案 `-Install <key>` 下载技能包，
  再按返回的 `entry=` 调用；不要因为“没装”就放弃或改用云端。
- `-Resolve` 返回 `progress_required=true` 的 skill，**首次调用必须实时展示模型下载进度条**，
  并在退出码 3 时用 `--continue` 续跑直到完成；不允许静默等待，也不允许改用云端方案。
- 仅限 Intel AIPC (Windows)、本地离线运行；非 Intel 硬件或云端推理请求要明确拒绝。

## 测试
运行离线冒烟测试（stdlib-only，menu/route 不联网；不校验真实下载）：
```powershell
powershell -ExecutionPolicy Bypass -File test_learning_bot.ps1
```
退出码 `0` = 所有检查通过。它会校验 registry（17 个预设 skill，且不得残留下载地址）、menu / route 的
`[SKILL_RESULT]` 契约，以及预设 vs. 非预设输入的路由建议是否符合预期。
