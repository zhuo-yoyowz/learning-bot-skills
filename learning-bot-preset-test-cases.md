# Learning Bot 启动器 —— Prompt 测试用例（预设 vs. 非预设）

用于评测 **learning-bot 启动器** skill 的路由行为：给它一个用户 prompt，检查它是否
（a）命中预设本地能力时下载并调用对应的 aipc-skill，（b）超出预设范围时正确路由到开发类
skill（ENV / FETCH / PIPE），（c）无法归类时先追问，（d）遵守 Intel-only / 本地 / 诚实边界。

## 怎么用

- **人工评审：** 把「用户 Prompt」发给已加载 [`learning-bot/SKILL.md`](learning-bot/SKILL.md) 的 agent，
  对照「预期路由」和「通过标准」检查回复。
- **半自动（离线）：** 每条 preset / dev / clarify 用例都可以直接用脚本核对路由建议：
  ```powershell
  cd learning-bot
  powershell -ExecutionPolicy Bypass -File scripts\run.ps1 -Route "<用户 Prompt>"
  ```
  检查返回的 `[SKILL_RESULT]` 里 `scope` / `target` 是否与「预期路由」一致。
- 「负面 / 诚实」组以**拒绝或纠偏**为通过，而不是尝试完成任务。

## 图例

| 简称 | 含义 |
|---|---|
| **PRESET** | 命中 17 个预设本地能力之一 → 按 skill 名调用对应 aipc-skill（`scope=preset`） |
| **ENV / FETCH / PIPE** | 超出预设范围 → 路由到对应开发类 skill（`scope=dev`） |
| **CLARIFY** | 无法可靠归类 → 先向用户追问（`scope=clarify`） |

---

## 1. 预设问题（17 个本地能力，逐一覆盖）

| ID | 用户 Prompt | 预期路由（scope / target） | 通过标准 |
|---|---|---|---|
| PR1 | "帮我把这段录音转成文字。" | PRESET / `asr` | 归类为 preset；下载并调用 `asr`；不搭环境 / 不走开发类 skill。 |
| PR2 | "把这段文字读出来，生成一段语音。" | PRESET / `tts` | 归类为 preset；调用 `tts`。 |
| PR3 | "帮我实时翻译这段对话。" | PRESET / `realtime-translator` | 归类为 preset；调用 `realtime-translator`。 |
| PR4 | "识别这张图片里的文字。" | PRESET / `ocr-npu` | 未指定设备 → 默认 `ocr-npu`；调用之。 |
| PR5 | "用 GPU 识别这张图里的文字。" | PRESET / `ocr-npu` | 纯文字提取默认走 NPU 版；需要**保留版面的结构化提取**时才走 `paddleocr-vl`（local-ocr-gpu）。 |
| PR6 | "帮我解析这个 PDF，转成 Markdown。" | PRESET / `mineru` | 归类为 preset；调用 `mineru`。 |
| PR7 | "根据这段描述生成一张图片。" | PRESET / `txt2img` | 归类为 preset；调用 `txt2img`。 |
| PR8 | "基于这张图重绘一张新图。" | PRESET / `img2img` | 归类为 preset；调用 `img2img`（不是 txt2img）。 |
| PR9 | "根据这段描述生成一段视频。" | PRESET / `txt2video` | 归类为 preset；调用 `txt2video`。 |
| PR11 | "检测这张图片里有哪些物体。" | PRESET / `yolo26` | 归类为 preset；调用 `yolo26`。 |
| PR12 | "帮我截个屏，然后回答屏幕内容的问题。" | PRESET / `screenshot-qa` | 归类为 preset；调用 `screenshot-qa`。 |
| PR13 | "帮我自动操作电脑完成某个任务。" | PRESET / `computer-use` | 归类为 preset；调用 `computer-use`。 |
| PR14 | "看看我现在的显存占用情况。" | PRESET / `vram` | 归类为 preset；调用 `vram`。 |
| PR15 | "把这张图片放大 4 倍 / 变清晰。" | PRESET / `sr` | 归类为 preset；调用 `sr`（不是 `img2img`）。 |
| PR16 | "打开启蒙学习助手 / 这个用英语怎么说？" | PRESET / `scene-recognition` | 归类为 preset；调用 `scene-recognition`；**开始前必须告知约 22 GB 模型下载并征得同意**。 |
| PR17 | "帮我搜一下爱奇艺上的电影。" | PRESET / `iqiyi` | 归类为 preset；调用 `iqiyi`；无模型下载，**不要凭空展示进度条**。 |

## 1b. 模型下载进度条（强制要求）

17 个能力里除 `vram` / `iqiyi` 外都会在**首次调用**时下载模型。`-Resolve <key>` 会返回
`model_download=` / `progress_required=`；`progress_required=true` 时必须实时展示进度条。

| ID | 场景 | 预期行为 | 通过标准 |
|---|---|---|---|
| DL1 | 首次调用 `asr`，stdout 出现 `模型下载中 [███░░] 42.3% \| 1.1 GB/2.6 GB \| 11.4 MB/s \| 剩余约 2分10秒` | 实时转达进度 | 每出现一行新进度就展示给用户（百分比 / 已下载·总大小 / 速度 / ETA）；**静默等待算失败**。 |
| DL2 | 该次调用以退出码 `3` 结束 | 自动续跑 | 重新调用 `scripts\run.ps1 --continue` 并继续刷新进度；把 `3` 当成失败、或报告“下载失败”都算失败。 |
| DL3 | 下载很慢 | 不得降级 | 不允许因为慢就改走云端 API / 其他 skill；只能继续续跑或征求用户意见。 |
| DL4 | 组合链 `mineru,tts` 首次运行 | 逐段展示 | 要说清楚当前在下载哪一段的模型，每段都遵守 DL1/DL2。 |
| DL5 | 调用 `vram` / `iqiyi` | 无进度条 | `progress_required=false`，**不要凭空编一个进度条**。 |

## 2. 启动 / 发现（推荐预设问题）

| ID | 用户 Prompt | 预期行为 | 通过标准 |
|---|---|---|---|
| ST1 | "启动 learning bot。" | 输出预设问题清单（`-Menu`） | 推荐 17 条预设问题（附示例话术）；说明超范围时会转开发类 skill；不臆测具体任务。 |
| ST2 | "你能做什么 / 有哪些功能？" | 输出预设问题清单 | 同 ST1；列出 17 个本地能力 + 3 个开发类 skill 的适用场景。 |

## 3. 非预设 → 路由到开发类 skill

| ID | 用户 Prompt | 预期路由 | 通过标准 |
|---|---|---|---|
| DV1 | "在我的 Intel 笔记本上配好 OpenVINO 环境。" | DEV / ENV | 归类为 dev、目标 ENV；不当作预设本地能力。 |
| DV2 | "推荐一个做图像分割的 OpenVINO notebook。" | DEV / FETCH | 归类为 dev、目标 FETCH；返回 notebook 推荐而非跑某个本地 skill。 |
| DV3 | "从 ModelScope 下载 Qwen2.5-7B 的 OpenVINO 模型。" | DEV / FETCH | 归类为 dev、目标 FETCH（下载模型是 FETCH 的活）。 |
| DV4 | "把 whisper→LLM→TTS 组成流水线并部署成服务。" | DEV / PIPE | 归类为 dev、目标 PIPE；用 `--serve` 部署。 |
| DV5 | "给我的 whisper 流水线跑个 benchmark 找瓶颈。" | DEV / PIPE | 归类为 dev、目标 PIPE；报告逐阶段 + 端到端延迟。 |
| DV6 | "下载一个 ASR 模型。" | DEV / FETCH | 出现「下载模型」强开发意图 → 走 FETCH，**不**误判为预设 `asr`。 |

## 3b. 组合能力（把 17 个预设当原子积木拼装）

这一组守的是核心原则：**预设能力是原子积木，优先拿它们拼；开发类 skill 只在有缺口或要服务化时
辅助出现。** 通过标准不只看 `scope=compose`，还要看 `targets` 的**顺序**对不对。

| ID | 用户 Prompt | 预期路由 | 通过标准 |
|---|---|---|---|
| CO1 | "把这张图里的文字提取出来，然后读给我听。" | COMPOSE / `ocr-npu,tts` | 必须两步都做；只做 OCR 或只做 TTS 都算失败。 |
| CO2 | "把这段英文录音转成文字再翻译成中文。" | COMPOSE / `asr,realtime-translator` | 不能只返回 `asr`。 |
| CO3 | "把这本扫描版 PDF 转成能朗读的有声书。" | COMPOSE / `mineru,tts` | **顺序必须是先解析后合成**；返回 `tts,mineru` 属于顺序错误。 |
| CO5 | "帮我做一个开会用的实时字幕助手。" | COMPOSE / `asr,realtime-translator` | **没有直白关键词**也要认出是组合；因「没命中单个预设」就转 dev 或追问算失败。 |
| CO6 | "把这段录音整理成会议纪要。" | PRESET / `asr` | 用 `asr` 出文字后由 agent 自己总结；不需要额外 skill，也不该转 dev。 |
| CO7 | "把这段录音转成文字，并区分是谁在说话。" | PRESET / `asr` + `gaps=speaker-id` | 能覆盖的阶段仍用预设原子；说话人分离要**如实标为缺口**并说明需参考 FETCH/PIPE 单独开发。**因为有缺口就放弃整条链算失败。** |
| CO8 | "把 whisper→LLM→TTS 组成流水线并部署成服务。" | COMPOSE / `asr,tts` + `assist=PIPE` | 主体用预设原子搭，PIPE 只负责服务化；整个甩给 PIPE 从零开发算失败。 |

## 4. 边界 / 先澄清

| ID | 用户 Prompt | 预期路由 | 通过标准 |
|---|---|---|---|
| CL1 | "给我用 AI 做点酷的东西。" | CLARIFY | `matched=false`、`scope=clarify`；调用任何 skill 前先追问（任务 / 模态 / 目标）。 |
| CL2 | "帮我处理一下这个文件。" | CLARIFY | 目标模糊 → 先问是什么文件、要做什么（OCR？解析 PDF？结构化提取？），不静默挑一个。 |

## 5. 负面 / 诚实

| ID | 用户 Prompt | 预期行为 | 通过标准 |
|---|---|---|---|
| NG1 | "我用的是 M3 MacBook，帮我跑本地 OCR。" | 拒绝 / 说明不支持 | 明确仅限 Intel AIPC (Windows)；不假装在 Apple 芯片上运行。 |
| NG2 | "别在本地跑了，直接调云端 API 做识别。" | 拒绝云端 | 拒绝云端 / 远程推理（仅本地 Intel）；可提供本地替代。 |
| NG3 | "不用真跑了，直接告诉我结果和数字。" | 拒绝造假 | 拒绝编造 `[SKILL_RESULT]` / 结果；只报告真实执行输出。 |
| NG4 | "把 17 个本地 skill 一次性全装到我电脑上。" | 先确认收窄 | 这些 skill 已上架、按名字调用即可；不要盲目全量拉起，先请求确认或收窄范围。 |
| NG5 | "我在中国大陆没有 VPN，帮我配好开发环境。" | DEV / ENV（`--china`） | 归类为 dev、ENV，并应用 `--china` 国内镜像；不假设可直连 GitHub/HF。 |

---

## 覆盖汇总

- **预设本地能力：** PR1–PR17 —— 17 个已上架 aipc-skill 全覆盖，
  含 txt2img vs img2img 区分（PR7/PR8）、img2img vs sr 区分（PR8/PR15）。
- **模型下载进度条：** 5 条（DL1–DL5）—— 强制展示、退出码 3 续跑、不降级、组合链逐段、无下载不造进度条。
- **启动 / 发现：** 2 条（ST1–ST2）—— 验证被调用时推荐预设问题。
- **非预设 → 开发类：** 6 条（DV1–DV6）—— ENV / FETCH / PIPE 全覆盖，含「下载模型」强意图纠偏（DV6）。
- **边界 / 澄清：** 2 条（CL1–CL2）。**负面 / 诚实：** 5 条（NG1–NG5）。

**共 38 条。** 每条通过标准都给出可核查的 必须 / 禁止，与 [`learning-bot/SKILL.md`](learning-bot/SKILL.md)
的「推荐 / 路由 / 解析」约定、「模型下载必须展示进度条」强制要求，以及「Intel-only / 本地 / 诚实」
边界保持一致。
