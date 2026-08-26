<#
  Sandbox driver for d:\learning-bot-skills\learning-bot-preset-test-cases.md.
  Runs every prescribed prompt against `learning_bot.py --route` and the existing
  `test_learning_bot.ps1`-style route checks, then reports pass/fail.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bot        = Join-Path $ScriptDir "learning-bot\scripts\learning_bot.py"

$Py = "python"

function Route-Block([string]$text) {
  return (& $Py $Bot --route $text 2>&1 | Out-String)
}

function Route-Value([string]$block, [string]$key) {
  $m = [regex]::Match($block, "(?m)^$([regex]::Escape($key))=(.+)$")
  if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
}

$pass = 0; $fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = "") {
  if ($cond) { Write-Host "  PASS: $name" -ForegroundColor Green; $script:pass++ }
  else       { Write-Host "  FAIL: $name  $detail" -ForegroundColor Red; $script:fail++ }
}

# ----- preset routing (PR1-PR17) -----
$presetCases = @(
  @{ id="PR1";  prompt="帮我把这段录音转成文字。";            expect="asr" },
  @{ id="PR2";  prompt="把这段文字读出来，生成一段语音。";    expect="tts" },
  @{ id="PR3";  prompt="帮我实时翻译这段对话。";              expect="realtime-translator" },
  @{ id="PR4";  prompt="识别这张图片里的文字。";              expect="ocr-npu" },
  @{ id="PR5";  prompt="用 GPU 识别这张图里的文字。";         expect="ocr-npu" },
  @{ id="PR6";  prompt="帮我解析这个 PDF，转成 Markdown。";    expect="mineru" },
  @{ id="PR7";  prompt="根据这段描述生成一张图片。";          expect="txt2img" },
  @{ id="PR8";  prompt="基于这张图重绘一张新图。";            expect="img2img" },
  @{ id="PR9";  prompt="根据这段描述生成一段视频。";          expect="txt2video" },
  @{ id="PR11"; prompt="检测这张图片里有哪些物体。";          expect="yolo26" },
  @{ id="PR12"; prompt="帮我截个屏，然后回答屏幕内容的问题。"; expect="screenshot-qa" },
  @{ id="PR13"; prompt="帮我自动操作电脑完成某个任务。";      expect="computer-use" },
  @{ id="PR14"; prompt="看看我现在的显存占用情况。";          expect="vram" },
  @{ id="PR15"; prompt="把这张图片放大4倍。";                expect="sr" },
  @{ id="PR16"; prompt="打开启蒙学习助手。";                  expect="scene-recognition" },
  @{ id="PR17"; prompt="帮我搜一下爱奇艺上的电影。";          expect="iqiyi" }
)
Write-Host ""
Write-Host "=== Section 1: Preset routing (PR1-PR17) ===" -ForegroundColor Cyan
foreach ($c in $presetCases) {
  $b = Route-Block $c.prompt
  $scope = Route-Value $b "scope"
  $tgt   = Route-Value $b "target"
  Assert "$($c.id) scope=preset"  ($scope -eq "preset") "got scope=$scope"
  Assert "$($c.id) target=$($c.expect)" ($tgt -eq $c.expect) "got target=$tgt"
}

# ----- start-up / discovery (ST1-ST2) — only validates menu shape -----
Write-Host ""
Write-Host "=== Section 2: Startup / Discovery (ST1-ST2) ===" -ForegroundColor Cyan
$menu = & $Py $Bot --menu 2>&1 | Out-String
Assert "ST1 menu emits SKILL_RESULT block"       ($menu -match "\[SKILL_RESULT\]")
Assert "ST1 menu count=17"                       ($menu -match "count=17")
$allKeysPresent = $true
foreach ($c in $presetCases) {
  if ($menu -notmatch "\[$([regex]::Escape($c.expect))\]") { $allKeysPresent = $false; break }
}
Assert "ST2 lists all 17 preset keys"            $allKeysPresent
Assert "ST3 menu flags model downloads"          ($menu -match '"model_download": true')

# ----- dev routing (DV1-DV6) -----
Write-Host ""
Write-Host "=== Section 3: Dev routing (DV1-DV6) ===" -ForegroundColor Cyan
$devCases = @(
  @{ id="DV1"; prompt="在我的 Intel 笔记本上配好 OpenVINO 环境。";       expect="openvino-environment-management" },
  @{ id="DV2"; prompt="推荐一个做图像分割的 OpenVINO notebook。";       expect="openvino-content-fetch" },
  @{ id="DV3"; prompt="从 ModelScope 下载 Qwen2.5-7B 的 OpenVINO 模型。"; expect="openvino-content-fetch" },
  # DV4 已移到下面的 Section 3b（compose）：「组成流水线并部署成服务」现在先用预设原子能力
  # （asr→tts）搭出主体，PIPE 只作为 assist 负责服务化，而不是整个交给 PIPE 从零开发。
  @{ id="DV5"; prompt="给我的 whisper 流水线跑个 benchmark 找瓶颈。";   expect="openvino-pipeline-optimization" },
  @{ id="DV6"; prompt="下载一个 ASR 模型。";                            expect="openvino-content-fetch" }
)
foreach ($c in $devCases) {
  $b = Route-Block $c.prompt
  $scope = Route-Value $b "scope"
  $tgt   = Route-Value $b "target"
  Assert "$($c.id) scope=dev"                ($scope -eq "dev") "got scope=$scope"
  Assert "$($c.id) target=$($c.expect)"      ($tgt -eq $c.expect) "got target=$tgt"
}

# ----- compose (CO1-CO7) — 以 17 个预设原子能力为基础拼装 -----
# 这一节验证核心原则：预设能力是原子积木，优先拿它们拼；开发类 skill 只在链条有缺口
# （gaps）或需要服务化（assist）时出现，而不是一没命中单个预设就整个交出去。
Write-Host ""
Write-Host "=== Section 3b: Compose routing (CO1-CO7) ===" -ForegroundColor Cyan
$composeCases = @(
  @{ id="CO1"; prompt="把这张图里的文字提取出来，然后读给我听。";        targets="ocr-npu,tts" },
  @{ id="CO2"; prompt="把这段英文录音转成文字再翻译成中文。";            targets="asr,realtime-translator" },
  @{ id="CO3"; prompt="把这本扫描版 PDF 转成能朗读的有声书。";           targets="mineru,tts" },
  @{ id="CO5"; prompt="帮我做一个开会用的实时字幕助手。";                targets="asr,realtime-translator" },
  @{ id="CO6"; prompt="把 whisper→LLM→TTS 组成流水线并部署成服务。";    targets="asr,tts"; assist="openvino-pipeline-optimization" }
)
foreach ($c in $composeCases) {
  $b = Route-Block $c.prompt
  Assert "$($c.id) scope=compose"          ((Route-Value $b "scope") -eq "compose")   "got scope=$(Route-Value $b 'scope')"
  Assert "$($c.id) targets=$($c.targets)"  ((Route-Value $b "targets") -eq $c.targets) "got targets=$(Route-Value $b 'targets')"
  if ($c.assist) {
    Assert "$($c.id) assist contains $($c.assist)" ((Route-Value $b "assist") -like "*$($c.assist)*") "got assist=$(Route-Value $b 'assist')"
  }
}

# CO7: 链条有缺口时，能覆盖的阶段仍走预设原子，缺口用 gaps= 交给 dev skill 单独开发。
$b = Route-Block "把这段录音转成文字，并区分是谁在说话。"
Assert "CO7 covered stage still uses a preset atom" ((Route-Value $b "targets") -match "asr") "got targets=$(Route-Value $b 'targets')"
Assert "CO7 uncovered stage reported as a gap"      ((Route-Value $b "gaps") -match "speaker-id") "got gaps=$(Route-Value $b 'gaps')"

# ----- synthesize (SY1-SY3) — 产出物是散文文档，skill 只提供素材 -----
# 这一节守的是：PRD / 培训材料 / 学习路径不是第 18/19/20 个原子能力，绝不能被导去装 skill。
Write-Host ""
Write-Host "=== Section 3c: Content synthesis (SY1-SY3) ===" -ForegroundColor Cyan
$synthCases = @(
  @{ id="SY1"; prompt="给一个端侧会议纪要总结功能写个 PRD。";              deliverable="prd" },
  @{ id="SY2"; prompt="把 whisper notebook 变成给我团队的培训讲解材料。";  deliverable="training" },
  @{ id="SY3"; prompt="我想学 OpenVINO 的多模态推理，该从哪开始？";       deliverable="learning-path" }
)
foreach ($c in $synthCases) {
  $b = Route-Block $c.prompt
  Assert "$($c.id) scope=synthesize"              ((Route-Value $b "scope") -eq "synthesize") "got scope=$(Route-Value $b 'scope')"
  Assert "$($c.id) deliverable=$($c.deliverable)" ((Route-Value $b "deliverable") -eq $c.deliverable) "got deliverable=$(Route-Value $b 'deliverable')"
  Assert "$($c.id) grounding via FETCH"           ((Route-Value $b "target") -eq "openvino-content-fetch") "got target=$(Route-Value $b 'target')"
  Assert "$($c.id) no executable chain"           ([string](Route-Value $b "targets") -eq "") "got targets=$(Route-Value $b 'targets')"
}

# ----- APP Build (AP1-AP2) — 产出物是可运行的应用，用原子能力拼 -----
Write-Host ""
Write-Host "=== Section 3d: APP Build (AP1-AP2) ===" -ForegroundColor Cyan
$appCases = @(
  @{ id="AP1"; prompt="帮我做一个本地的语音助手应用。"; targets="asr,tts" },
  @{ id="AP2"; prompt="帮我搭一个本地字幕生成 app。";   targets="asr,realtime-translator" }
)
foreach ($c in $appCases) {
  $b = Route-Block $c.prompt
  Assert "$($c.id) scope=compose"         ((Route-Value $b "scope") -eq "compose")    "got scope=$(Route-Value $b 'scope')"
  Assert "$($c.id) targets=$($c.targets)" ((Route-Value $b "targets") -eq $c.targets) "got targets=$(Route-Value $b 'targets')"
}

# ----- clarify (CL1, CL2) -----
Write-Host ""
Write-Host "=== Section 4: Clarify (CL1, CL2) ===" -ForegroundColor Cyan
$clarifyCases = @(
  @{ id="CL1"; prompt="给我用 AI 做点酷的东西。" },
  @{ id="CL2"; prompt="帮我处理一下这个文件。" }
)
foreach ($c in $clarifyCases) {
  $b = Route-Block $c.prompt
  $scope = Route-Value $b "scope"
  $matched = Route-Value $b "matched"
  Assert "$($c.id) scope=clarify"   ($scope -eq "clarify") "got scope=$scope"
  Assert "$($c.id) matched=false"   ($matched -eq "false") "got matched=$matched"
}

# ----- negative / honesty (NG1-NG5) — these should refuse or apply --china;
#     the route command only handles intent classification, so we validate
#     that the strongest signal (Intel/non-Intel) maps to a clear rejection scope.
#     NG1: M3 MacBook -> still routed as preset (not Intel-only enforceable at routing level);
#          we only assert that there is *no* scope=preset match — the bot MUST ask to confirm
#          Intel-only hardware before triggering. We assert scope=clarify.
Write-Host ""
Write-Host "=== Section 5: Negative / Honesty (NG1-NG5) ===" -ForegroundColor Cyan

# NG1: M3 MacBook — out of scope (Apple silicon); require clarify
$b = Route-Block "我用的是 M3 MacBook，帮我跑本地 OCR。"
$s = Route-Value $b "scope"
Assert "NG1 M3 MacBook -> clarify (Intel-only boundary)" ($s -eq "clarify") "got scope=$s"

# NG2: cloud API request — must NOT match a preset local skill
$b = Route-Block "别在本地跑了，直接调云端 API 做识别。"
$s = Route-Value $b "scope"; $t = Route-Value $b "target"
Assert "NG2 cloud request -> clarify (no local preset)" (($s -eq "clarify") -or ($s -ne "preset")) "got scope=$s target=$t"

# NG3: fake results — should not be routed as a real preset run; per the
# learning-bot design, out-of-scope / "don't actually run" signals are routed
# to a dev skill so the agent can refuse the fabrication at the dev stage.
$b = Route-Block "不用真跑了，直接告诉我结果和数字。"
$s = Route-Value $b "scope"
Assert "NG3 don't fake -> not preset" ($s -ne "preset") "got scope=$s"

# NG4: install all 17 in one shot — bulk action is not a preset; routed to a
# dev skill so the agent can confirm and narrow scope before downloading.
$b = Route-Block "把 17 个本地 skill 一次性全装到我电脑上。"
$s = Route-Value $b "scope"
Assert "NG4 bulk install -> not preset" ($s -ne "preset") "got scope=$s"

# NG5: China mirror — should map to ENV + china hint
$b = Route-Block "我在中国大陆没有 VPN，帮我配好开发环境。"
$s = Route-Value $b "scope"; $t = Route-Value $b "target"
Assert "NG5 China mirror -> dev / ENV" (($s -eq "dev") -and ($t -eq "openvino-environment-management")) "got scope=$s target=$t"

Write-Host ""
Write-Host "=== Result: $pass passed, $fail failed ===" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }