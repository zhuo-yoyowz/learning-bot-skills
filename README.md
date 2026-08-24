# Learning Bot Skills

A set of OpenVINO skills for a local **Learning Bot** on Intel AIPC (Windows). The bot turns a
natural-language request into a concrete result — a configured environment, recommended learning
material, or a runnable, optimized, served demo — by orchestrating the three skills below. Everything
runs locally and is offline / China-network capable (`-China`).

## Skills

| Skill | What it does |
|---|---|
| [`learning-bot`](learning-bot/) | **Entry / launcher.** Starts the Learning Bot: recommends a set of 17 preset questions, each mapped to a **published** local aipc-skill (Local ASR / Local TTS / Local T2I / Local computer use / Local OCR on NPU / local-mineru / local-screenshot-qa / local-vram / local-img2img / local-realtime-translator / local-txt2video / local-ocr-gpu / local-yolo26 / local-sr / local-scene-recognition / iqiyi / game-assistant-walkthrough). Resolves a preset hit to its published skill name for the host to invoke; routes out-of-scope requests to the three dev skills below. |
| [`openvino-environment-management`](openvino-environment-management/) | Configure the Intel AIPC dev environment on Windows (Python, Git, ModelScope, OpenVINO, PyTorch; optional CMake / Visual Studio). |
| [`openvino-content-fetch`](openvino-content-fetch/) | Fetch, parse, and index notebooks / samples / models / articles from GitHub, ModelScope AI PC Zone, and CSDN; returns a structured `[SKILL_RESULT]`. Also locates and downloads models / pre-converted OpenVINO IR from ModelScope and the Intel OpenVINO Model Hub. |
| [`openvino-pipeline-optimization`](openvino-pipeline-optimization/) | Scaffold a multi-model OpenVINO pipeline from notebook(s): discover stages → optimize (device + precision) → benchmark → serve (client + server) → optionally **package the pipeline as a distributable local AI skill** (fixed `run.ps1` entry + client-server named-pipe + model download/resume + SKILL.md routing; integrated from [`local-ai-skill-authoring`](https://github.com/openvino-dev-samples/local-ai-skill-authoring)). |

The `learning-bot` skill is the **entry point**: it presents preset questions and routes each request
to a preset local skill or, when out of scope, to one of the three dev skills. The 17 preset skills
(Intel AI PC Skills release 1.0.9) are **already published** — `learning-bot -Resolve <key>` maps an
internal key to the published skill name and the host invokes it by that name; this repo no longer
hosts any download URL.

### Model-download progress is mandatory

15 of the 17 preset skills download models on their first invocation (`local-vram` and `iqiyi` do
not). `-Resolve <key>` reports this as `model_download=` / `progress_required=`. When
`progress_required=true`, the host agent **MUST** relay the skill's `模型下载中 [███░░] 42.3% |
1.1 GB/2.6 GB | 11.4 MB/s | 剩余约 2分10秒` stdout lines to the user in real time (render them as a
progress bar), and keep re-invoking `scripts\run.ps1 --continue` on exit code `3` until the download
completes. Silent waiting, or silently falling back to a cloud API, is not allowed.

## Prepared Questions

Every skill can emit a set of **prepared questions** for the agent to render as an interactive
checklist before running its main flow — offline, no venv/network needed. Three types, one shared
`[SKILL_QUESTIONS]` contract:

| Type | Purpose |
|---|---|
| `preset` | Recommend what the skill can do ("you can ask me these") |
| `preflight` | Multi-select prerequisite confirmation; each option can carry `on_missing` → the skill/step to run first for anything left unchecked |
| `clarify` | Disambiguate an ambiguous request |

```powershell
# script-based skills (pipeline-optimization / content-fetch): via run.ps1
run.ps1 --questions preflight        # pipeline (also -Questions on content-fetch)
# environment-management (scripts at root, no run.ps1): call questions.ps1 directly
powershell -ExecutionPolicy Bypass -File questions.ps1 -Type preflight
# learning-bot: preset is generated from its registry
run.ps1 -Questions all
```

Contract:

```
[SKILL_QUESTIONS]
skill=<name>
type=preset|preflight|clarify|all
count=<number of question blocks>
data=<compact JSON array; each block {type,id,prompt,multiselect,options:[{key,label,example?,exclusive?,on_missing?}]}>
[/SKILL_QUESTIONS]
```

Questions live in each skill's `questions.json`; the shared `questions.ps1` (or `learning_bot.py
--questions` for the launcher) emits the block. `exclusive` options (e.g. "以上均完成，无需引导我")
clear the rest; `on_missing` routes unmet prerequisites to `openvino-environment-management`,
`openvino-content-fetch`, or a `self:<action>` step.

## 测试

分三层。L1 是离线的脚本层回归测试，L2/L3 验证**真实 agent 读完 SKILL.md 后会不会做对** ——
详见 [`agent-eval/README.md`](agent-eval/README.md)。

```powershell
# L1 契约层：跨 skill 的回归测试（离线、不联网、不安装任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File test_contracts.ps1

# L1 各 skill 自己的冒烟测试
powershell -NoProfile -ExecutionPolicy Bypass -File learning-bot\test_learning_bot.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File openvino-content-fetch\test_content_fetch.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File openvino-pipeline-optimization\test_pipeline.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File openvino-environment-management\test_questions.ps1

# L2/L3 agent 层：在 TRAE / Cursor / Cline 里跑 agent-eval/cases.jsonl 的用例后判分
powershell -NoProfile -ExecutionPolicy Bypass -File agent-eval\grade.ps1 -Transcript .\transcript.txt
```

`test_contracts.ps1` 守的是「文档写的 == 脚本做的」：每个 `.ps1` 能否解析、`param()` 是否是第一个
语句、SKILL.md 里出现的参数能否真的绑上、有没有裸 `Read-Host`、未知参数是否显式报错、
`--dry-run` 是否真的不下载。退出码 `0` = 全部通过。

## Learning Bot

- **[`learning-bot-system-prompt.md`](learning-bot-system-prompt.md)** — the system prompt for the
  orchestration agent (role, skill routing, honesty & limits, response style).
- **[`learning-bot-test-cases.md`](learning-bot-test-cases.md)** — prompt test cases for evaluating the
  bot's intent classification, skill selection/ordering, and boundary handling.
- **[`learning-bot-preset-test-cases.md`](learning-bot-preset-test-cases.md)** — prompt test cases for
  the `learning-bot` launcher: preset vs. non-preset routing, discovery, boundaries, and honesty.

## 如何调用本仓库的任意 skill

四个 skill 的**调用形式统一**如下。不要简写成 `run.ps1 -Menu` —— PowerShell 不会从当前目录执行
裸文件名，而且脚本大多在 `scripts/` 子目录下，简写形式必然报 `not recognized`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<入口脚本绝对路径>" <参数>
```

| Skill | 入口脚本 | 参数风格 |
|---|---|---|
| `learning-bot` | `learning-bot/scripts/run.ps1` | 单连字符 `-Menu` / `-Route` / `-Resolve` / `-Capacity` / `-CanRun` |
| `openvino-content-fetch` | `openvino-content-fetch/scripts/run.ps1` | 单连字符 `-Source` / `-Download` / `-Questions` |
| `openvino-pipeline-optimization` | `openvino-pipeline-optimization/scripts/run.ps1` | 双连字符 `--slug` / `--dry-run` / `--questions` |
| `openvino-environment-management` | `precheck_env.ps1` 和 `intel_aipc_env_setup.ps1`（**在技能根目录，没有 `scripts/`**） | 单连字符 `-China` / `-InstallCmake` / `-Yes` |

**给 agent 的通用约定：**

- **退出码**：`0` = 成功，`1` = 失败。
- **判断成败只看 `[SKILL_RESULT]` 里的 `status=`**，不要因为「有输出」就断定成功。
- **`[SKILL_QUESTIONS]` 是问题清单，不是结果汇报，它没有也不需要 `status=`** —— 只有
  `[SKILL_RESULT]` 才看 `status=`。两个块用途不同，不要互相套用。
- **未知参数不会被静默忽略**：任何拼错的参数都会返回 `status=error` + `reason=unknown-argument`
  并退出 1。看到它就是拼写错了，去对照上表的参数风格，而不是原样重试。
- **不要用参数缩写**：例如 pipeline 的 `-s` 会同时匹配 `slug/serve/status/stop` 而报
  `AmbiguousParameter`。一律写完整参数名。
- **零成本探路命令**（不联网、不建 venv、不下载）：各 skill 的 `-Questions` / `--questions`、
  `-Status` / `--status`、pipeline 的 `--dry-run`、env 的 `precheck_env.ps1`。不确定时先跑这些。
- **非交互式环境**（agent / CI）调用 env skill 时加 `-Yes`，脚本不会停下来等 stdin。
- **推荐模型前先看装不装得下**：`learning-bot -Capacity` 探测本机预算（写缓存
  `~/.openvino/capacity.json`），`-CanRun <model>` 判定可行性；content-fetch 下载模型时会自动
  带上 `fits` / `need_gb` / `budget_gb`。**iGPU 的显存与系统内存同源，不能相加** ——
  直接用 `usable_budget_gb`。

## Requirements

- Intel AIPC (Windows) — Intel Ultra series or Intel Arc recommended for NPU/GPU acceleration.
- Each skill's `SKILL.md` documents its parameters, usage, and (where applicable) the `[SKILL_RESULT]`
  contract.

## Usage

Each skill is invoked via its own entry script / instructions in `SKILL.md`. Add `-China` (or
`--china`) to use domestic mirrors (pip / ModelScope / HF-mirror / GitCode) when GitHub/HF aren't
directly reachable.
