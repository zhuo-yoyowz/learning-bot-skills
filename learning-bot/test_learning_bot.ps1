<#
  Smoke test for the learning-bot launcher skill.

  Offline & network-free: exercises menu + routing (stdlib-only) and validates the skills
  registry (17 published preset skills) and the [SKILL_RESULT] contracts. Nothing here
  touches the network: the skills are already published and are invoked by skill_name.

  Usage:  powershell -ExecutionPolicy Bypass -File test_learning_bot.ps1
  Exit code 0 = all tests passed, 1 = one or more failed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Scripts   = Join-Path $ScriptDir "scripts"
$Bot       = Join-Path $Scripts "learning_bot.py"
$Registry  = Join-Path $Scripts "skills_registry.json"

$VenvPy = Join-Path $env:USERPROFILE ".openvino\venv-contentfetch\Scripts\python.exe"
$Py = if (Test-Path $VenvPy) { $VenvPy } else { "python" }

$pass = 0; $fail = 0
function Check($name, [scriptblock]$cond) {
  $ok = $false
  try { $ok = (& $cond) } catch { $ok = $false }
  if ($ok) { Write-Host "  PASS: $name" -ForegroundColor Green; $script:pass++ }
  else     { Write-Host "  FAIL: $name" -ForegroundColor Red;   $script:fail++ }
}

Write-Host "=== learning-bot smoke test ===" -ForegroundColor Cyan
Write-Host "python: $Py"

Write-Host ""
Write-Host "1. Script compiles & --help works (stdlib-only)" -ForegroundColor White
Check "py_compile learning_bot.py" { & $Py -m py_compile $Bot; $LASTEXITCODE -eq 0 }
& $Py $Bot --menu | Out-Null
Check "--menu exit 0"             { $LASTEXITCODE -eq 0 }

Write-Host ""
Write-Host "2. Registry is well-formed (17 preset skills + 3 dev skills)" -ForegroundColor White
$reg = $null
try { $reg = Get-Content -Raw -Encoding UTF8 $Registry | ConvertFrom-Json } catch { $reg = $null }
Check "registry parses as JSON"        { $null -ne $reg }
Check "release block points at 1.0.9" {
  ($reg.release.tag -eq "1.0.9") -and ($reg.release.base_url -like "https://github.com/makejiang/aipc-skills/releases/download/1.0.9/*")
}
Check "every preset carries a fallback zip" {
  $bad = $reg.preset_skills | Where-Object { -not $_.zip -or ($_.zip -notlike "*.zip") }
  ($bad | Measure-Object).Count -eq 0
}
Check "every preset carries an explicit backup_url" {
  $bad = $reg.preset_skills | Where-Object {
    -not $_.backup_url -or ($_.backup_url -ne ($reg.release.base_url + $_.zip))
  }
  ($bad | Measure-Object).Count -eq 0
}
Check "17 preset skills"               { $reg.preset_skills.Count -eq 17 }
Check "3 dev skills (ENV/FETCH/PIPE)"  { $reg.dev_skills.Count -eq 3 }
Check "every preset has key/skill_name/question/keywords" {
  $bad = $reg.preset_skills | Where-Object { -not $_.key -or -not $_.skill_name -or -not $_.question -or -not $_.keywords }
  ($bad | Measure-Object).Count -eq 0
}
Check "every preset declares has_model_download" {
  $bad = $reg.preset_skills | Where-Object { $null -eq $_.has_model_download }
  ($bad | Measure-Object).Count -eq 0
}
Check "only vram/iqiyi are download-free" {
  $free = @($reg.preset_skills | Where-Object { -not $_.has_model_download } | ForEach-Object { $_.key } | Sort-Object)
  (($free -join ",") -eq "iqiyi,vram")
}
# 与 Intel AI PC Skills 清单（docx / release 1.0.9）逐条对应的 17 个已上架能力
$expectedKeys = @("asr","tts","txt2img","computer-use","ocr-npu","mineru","screenshot-qa","vram","img2img","realtime-translator","txt2video","paddleocr-vl","yolo26","sr","scene-recognition","iqiyi","game-guide")
Check "all 17 expected keys present" {
  $have = $reg.preset_skills | ForEach-Object { $_.key }
  ($expectedKeys | Where-Object { $have -notcontains $_ } | Measure-Object).Count -eq 0
}
Check "retired desktop-pet is gone" {
  ($reg.preset_skills | ForEach-Object { $_.key }) -notcontains "desktop-pet"
}

Write-Host ""
Write-Host "3. Menu emits a valid [SKILL_RESULT] (action=menu, count=17)" -ForegroundColor White
$menu = & $Py $Bot --menu 2>&1 | Out-String
Check "menu SKILL_RESULT block" { $menu -match "\[SKILL_RESULT\]" -and $menu -match "\[/SKILL_RESULT\]" }
Check "menu action=menu"        { $menu -match "action=menu" }
Check "menu count=17"           { $menu -match "count=17" }
Check "menu carries model_download flags" { $menu -match '"model_download": true' }
# PS 5.1 的 ConvertFrom-Json 对顶层数组不做枚举，这里直接数原文里的字段出现次数更稳。
Check "menu carries a backup_url per skill" {
  $hits = [regex]::Matches($menu, '"backup_url": "https://github\.com/makejiang/aipc-skills/releases/download/1\.0\.9/[^"]+\.zip"')
  $hits.Count -eq 17
}

Write-Host ""
Write-Host "3b. Resolve exposes the download-progress contract" -ForegroundColor White
$rAsr = & $Py $Bot --resolve asr 2>&1 | Out-String
Check "resolve asr -> skill_name=Local ASR"     { $rAsr -match "skill_name=Local ASR" }
Check "resolve asr -> progress_required=true"   { $rAsr -match "progress_required=true" }
Check "resolve asr -> progress_note present"    { $rAsr -match "progress_note=" }
$rVram = & $Py $Bot --resolve vram 2>&1 | Out-String
Check "resolve vram -> progress_required=false" { $rVram -match "progress_required=false" }
Check "resolve vram -> no progress_note"        { $rVram -notmatch "progress_note=" }
$rSr = & $Py $Bot --resolve sr 2>&1 | Out-String
Check "resolve sr -> skill_name=local-sr"       { $rSr -match "skill_name=local-sr" }
Check "resolve sr -> fallback_url on the 1.0.9 release" {
  $rSr -match "fallback_url=https://github\.com/makejiang/aipc-skills/releases/download/1\.0\.9/skill-local-sr-[^\r\n]*\.zip"
}
$rBad = & $Py $Bot --install not-a-skill 2>&1 | Out-String
Check "install unknown key -> status=error"     { $rBad -match "status=error" -and $rBad -match "action=install" }

Write-Host ""
Write-Host "4. Routing: preset inputs map to the expected preset skill" -ForegroundColor White
$presetCases = @{
  "帮我把这段录音转成文字"          = "asr"
  "把这段文字读出来生成语音"        = "tts"
  "帮我实时翻译这段对话"            = "realtime-translator"
  "识别这张图片里的文字"            = "ocr-npu"
  "用 GPU 识别这张图里的文字"       = "ocr-npu"
  "帮我解析这个 PDF 转成 markdown"  = "mineru"
  "根据这段描述生成一张图片"        = "txt2img"
  "基于这张图重绘一张新图"          = "img2img"
  "根据描述生成一段视频"            = "txt2video"
  "检测这张图片里有哪些物体"        = "yolo26"
  "帮我截个屏回答屏幕内容的问题"    = "screenshot-qa"
  "帮我自动操作电脑完成任务"        = "computer-use"
  "看看我现在的显存占用"            = "vram"
  "把这张图片放大4倍"                = "sr"
  "打开启蒙学习助手"                = "scene-recognition"
  "帮我搜一下爱奇艺上的电影"        = "iqiyi"
}
foreach ($k in $presetCases.Keys) {
  $want = $presetCases[$k]
  $out = & $Py $Bot --route $k 2>&1 | Out-String
  Check "route '$k' -> scope=preset"        { $out -match "scope=preset" }
  Check "route '$k' -> target=$want"        { $out -match ("target=" + [regex]::Escape($want) + "\b") }
}

Write-Host ""
Write-Host "4b. Routing: composite requests chain preset atoms (scope=compose)" -ForegroundColor White
# 核心原则的回归测试：17 个预设能力是原子积木。需要多个能力的请求必须组合成一条有序链，
# 而不是截断成单个 preset，更不是因为「没有单个 skill 能做」就整个甩给开发类 skill。
$composeCases = @{
  "把这张图里的文字提取出来，然后读给我听"   = "ocr-npu,tts"
  "把这段英文录音转成文字再翻译成中文"       = "asr,realtime-translator"
  "把这本扫描版 PDF 转成能朗读的有声书"      = "mineru,tts"
  "帮我做一个开会用的实时字幕助手"           = "asr,realtime-translator"
}
foreach ($k in $composeCases.Keys) {
  $want = $composeCases[$k]
  $out = & $Py $Bot --route $k 2>&1 | Out-String
  Check "route '$k' -> scope=compose"  { $out -match "scope=compose" }
  Check "route '$k' -> targets=$want"  { $out -match ("targets=" + [regex]::Escape($want) + "\r?\n") }
}

# 「部署成服务」不再整个交给 PIPE：主体仍用预设原子能力，PIPE 只进 assist。
$svc = & $Py $Bot --route "把 whisper→LLM→TTS 组成流水线并部署成服务" 2>&1 | Out-String
Check "deploy request -> scope=compose"       { $svc -match "scope=compose" }
Check "deploy request -> targets=asr,tts"     { $svc -match "targets=asr,tts\r?\n" }
Check "deploy request -> PIPE only assists"   { $svc -match "assist=[^\r\n]*openvino-pipeline-optimization" }

# 链条有缺口时：能覆盖的阶段照常用预设原子，缺口用 gaps= 交出去单独开发。
$gap = & $Py $Bot --route "把这段录音转成文字，并区分是谁在说话" 2>&1 | Out-String
Check "gap request -> covered stage still preset"     { $gap -match "targets=[^\r\n]*asr" }
Check "gap request -> uncovered stage in gaps"        { $gap -match "gaps=[^\r\n]*speaker-id" }
Check "gap request -> FETCH offered to build the gap" { $gap -match "assist=[^\r\n]*openvino-content-fetch" }

Write-Host ""
Write-Host "4c. Routing: content deliverables map to scope=synthesize" -ForegroundColor White
# PRD / 培训材料 / 学习路径的产出物是散文文档：没有可安装的 skill，也没有推理要跑。
# 这一节守两件事：(1) 认得出来；(2) 绝不把它们导去装 preset skill。
$synthCases = @{
  "给一个端侧会议纪要总结功能写个 PRD。"             = "prd"
  "帮我写一份端侧 AI 功能的产品需求文档。"            = "prd"
  "把 whisper notebook 变成给我团队的培训讲解材料。"  = "training"
  "我想学 OpenVINO 的多模态推理，该从哪开始？"       = "learning-path"
  "帮我规划一条 OpenVINO 学习路径。"                = "learning-path"
}
foreach ($k in $synthCases.Keys) {
  $want = $synthCases[$k]
  $out = & $Py $Bot --route $k 2>&1 | Out-String
  Check "route '$k' -> scope=synthesize"    { $out -match "scope=synthesize" }
  Check "route '$k' -> deliverable=$want"   { $out -match ("deliverable=" + [regex]::Escape($want) + "\r?\n") }
  Check "route '$k' -> grounding via FETCH" { $out -match "target=openvino-content-fetch" }
  # 没有可执行的链条：targets 必须为空，否则弱 agent 会去 -Install 一个不存在的东西。
  Check "route '$k' -> targets is empty"    { $out -match "targets=\r?\n" }
}

# 回归：这条曾经被「会议纪要」的组合配方抢走，误判成 preset/asr。
$prd = & $Py $Bot --route "给一个端侧会议纪要总结功能写个 PRD。" 2>&1 | Out-String
Check "PRD request is NOT routed to a preset skill" { $prd -notmatch "scope=preset" }

Write-Host ""
Write-Host "4d. Routing: APP Build requests compose preset atoms" -ForegroundColor White
# APP Build 与上面三类相反：产出物是可运行的应用，就该用原子能力拼出来。
$appCases = @{
  "帮我做一个本地的语音助手应用。"   = "asr,tts"
  "帮我搭一个本地字幕生成 app。"    = "asr,realtime-translator"
  "做一个能把 PDF 读出来的小工具。" = "mineru,tts"
}
foreach ($k in $appCases.Keys) {
  $want = $appCases[$k]
  $out = & $Py $Bot --route $k 2>&1 | Out-String
  Check "route '$k' -> scope=compose"  { $out -match "scope=compose" }
  Check "route '$k' -> targets=$want"  { $out -match ("targets=" + [regex]::Escape($want) + "\r?\n") }
}

Write-Host ""
Write-Host "5. Routing: non-preset (dev) inputs map to ENV/FETCH/PIPE" -ForegroundColor White
$devCases = @{
  "帮我在 Intel 笔记本上搭环境配置 OpenVINO" = "openvino-environment-management"
  "推荐一个做图像分割的 notebook"            = "openvino-content-fetch"
  "从 ModelScope 下载模型"                   = "openvino-content-fetch"
  "把这几个模型组装成流水线并部署服务"       = "openvino-pipeline-optimization"
  "给我的流水线跑个 benchmark 找瓶颈"        = "openvino-pipeline-optimization"
}
foreach ($k in $devCases.Keys) {
  $want = $devCases[$k]
  $out = & $Py $Bot --route $k 2>&1 | Out-String
  Check "route '$k' -> scope=dev"     { $out -match "scope=dev" }
  Check "route '$k' -> target=$want"  { $out -match ("target=" + [regex]::Escape($want)) }
}

Write-Host ""
Write-Host "6. Routing: ambiguous input asks to clarify" -ForegroundColor White
$amb = & $Py $Bot --route "给我用 AI 做点酷的东西" 2>&1 | Out-String
Check "ambiguous -> scope=clarify"   { $amb -match "scope=clarify" }
Check "ambiguous -> matched=false"   { $amb -match "matched=false" }

Write-Host ""
Write-Host "7. Prepared questions ([SKILL_QUESTIONS] contract, offline)" -ForegroundColor White
function Test-Questions($expectSkill, $out) {
  $lines = $out -split "`r?`n"
  if ($lines -notcontains "[SKILL_QUESTIONS]" -or $lines -notcontains "[/SKILL_QUESTIONS]") { return $false }
  $sk = ($lines | Where-Object { $_ -like "skill=*" } | Select-Object -First 1)
  $cn = ($lines | Where-Object { $_ -like "count=*" } | Select-Object -First 1)
  $dt = ($lines | Where-Object { $_ -like "data=*" } | Select-Object -First 1)
  if (-not $sk -or -not $cn -or -not $dt) { return $false }
  if ($sk -ne "skill=$expectSkill") { return $false }
  try { $arr = $dt.Substring(5) | ConvertFrom-Json } catch { return $false }
  return (@($arr).Count -eq [int]$cn.Substring(6)) -and (@($arr).Count -gt 0)
}
foreach ($t in @("preset","preflight","clarify","all")) {
  $qo = & $Py $Bot --questions $t 2>&1 | Out-String
  Check "questions --questions $t valid block" { Test-Questions "learning-bot" $qo }
}
# preset is single-sourced from the registry (17 preset skills)
$qp = & $Py $Bot --questions preset 2>&1 | Out-String
$qpCount = if ($qp -match "count=(\d+)") { [int]$Matches[1] } else { -1 }
Check "preset question offers all 17 skills" {
  $dt = ($qp -split "`r?`n" | Where-Object { $_ -like "data=*" } | Select-Object -First 1)
  if (-not $dt) { return $false }
  try { $arr = @($dt.Substring(5) | ConvertFrom-Json) } catch { return $false }
  ($arr[0].options | Measure-Object).Count -eq 17
}

Write-Host ""
Write-Host "=== Section 6: 资源检测与模型可行性 ===" -ForegroundColor Cyan
# 这一节不触发真实硬件探测（--capacity 要起 OpenVINO，首次要一两分钟），
# 而是喂一份构造出来的 capacity 缓存，把估算逻辑本身钉住。

$CapReal   = Join-Path $env:USERPROFILE ".openvino\capacity.json"
$CapBackup = Join-Path $env:USERPROFILE ".openvino\capacity.testbak.json"
New-Item -ItemType Directory -Force -Path (Split-Path $CapReal) | Out-Null
$hadReal = Test-Path $CapReal
if ($hadReal) { Copy-Item $CapReal $CapBackup -Force }

try {
  # 模拟一台 8GB 显存的机器 —— 也就是用户最初提的那个场景。
  $fake = '{"source":"openvino","total_ram_gb":16,"free_ram_gb":9,"devices":["CPU","GPU"],' +
          '"gpu_type":"discrete","gpu_budget_gb":8,"shared_with_ram":false,' +
          '"safety_margin":0.85,"usable_budget_gb":6.8}'
  [System.IO.File]::WriteAllText($CapReal, $fake, (New-Object System.Text.UTF8Encoding($false)))

  # 8GB 显存跑不了 15B —— 这是本功能存在的理由，必须钉死。
  $r15 = & $Py $Bot --can-run "some-15B-model" --params 15 --precision INT4 2>&1 | Out-String
  Check "8GB budget: 15B INT4 -> fits=false"       { $r15 -match "fits=false" }
  Check "8GB budget: 15B INT4 gives alternatives"  { $r15 -match "alternatives=\S" }

  # 小模型必须判为能跑，否则就是过度保守、把能用的模型全挡了。
  $rs = & $Py $Bot --can-run "tiny-1.5B-INT4-OV" 2>&1 | Out-String
  Check "8GB budget: 1.5B INT4 -> fits=true"       { $rs -match "fits=true" }

  # model id 解析：7B 要认出来，2.5 那个版本号不能被当成参数量。
  $rp = & $Py $Bot --can-run "Qwen2.5-7B-Instruct-INT4-OV" 2>&1 | Out-String
  Check "model id parse: params_b=7 (not the 2.5 version)" { $rp -match "params_b=7(\.0)?" }
  Check "model id parse: precision=INT4"           { $rp -match "precision=INT4" }

  # 解析不出参数量时必须说 unknown，而不是编一个数字。
  $ru = & $Py $Bot --can-run "whisper-base" 2>&1 | Out-String
  Check "unparseable model id -> fits=unknown"     { $ru -match "fits=unknown" }
} finally {
  if ($hadReal) { Copy-Item $CapBackup $CapReal -Force; Remove-Item $CapBackup -Force -EA SilentlyContinue }
  else          { Remove-Item $CapReal -Force -EA SilentlyContinue }
}

# 离线纯净性：--route / --menu 不得依赖 capacity 缓存，缓存不在也要照常工作。
$noCap = & $Py $Bot --route "帮我把这段录音转成文字。" 2>&1 | Out-String
Check "route still works without a capacity cache" {
  ($noCap -match "scope=preset") -and ($noCap -match "target=asr")
}

Write-Host ""
Write-Host "=== Result: $pass passed, $fail failed ===" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
