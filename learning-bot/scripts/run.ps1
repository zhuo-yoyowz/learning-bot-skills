<#
  Learning Bot launcher - orchestrator entry point.

  Starts the Learning Bot: recommends the preset questions, routes a user utterance to a
  preset local skill (17 published aipc-skills) or a dev skill (ENV/FETCH/PIPE), and can
  resolve a preset key to its published skill name. All logic lives in scripts/learning_bot.py
  (stdlib only; menu / route / resolve are offline).

  -Install is the BACKUP path: when the host does not ship a preset skill, download its package
  from the AI PC Skills release (1.0.9) and unzip it locally. It is the only networked command here.

  Usage:
    run.ps1 -Menu                         # 打印推荐给用户的预设问题
    run.ps1 -Questions preflight          # 输出准备好的问题（preset/preflight/clarify/all）
    run.ps1 -Route "帮我把录音转成文字"    # 对一句用户输入给出路由建议
    run.ps1 -Resolve asr                  # 把 key 解析成上架后的官方 skill 名（离线）
    run.ps1 -Install asr [-OutDir <dir>] [-Force]   # 备用：宿主没预置时下载并解压技能包
#>
[CmdletBinding()]
param(
  [switch]$Menu,
  [ValidateSet("preset","preflight","clarify","all")][string]$Questions,
  [string]$Route,
  [string]$Resolve,
  [string]$Install,
  [string]$OutDir,
  [switch]$Force,
  [switch]$Capacity,
  [string]$CanRun,
  [double]$Params,
  [ValidateSet("INT4","INT8","FP16","FP32")][string]$Precision,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bot = Join-Path $ScriptDir "learning_bot.py"

# ---------------- 未知参数守卫 ----------------
# 没有这一段时，PowerShell 会静默丢弃它不认识的参数写法，脚本落到默认分支（打印菜单）并返回 0。
# 对 agent 来说这看起来像「命令成功了」，实际它要的动作根本没发生。这里显式报错并停下。
if ($Rest -and $Rest.Count -gt 0) {
  Write-Host "[SKILL_RESULT]"
  Write-Host "status=error"
  Write-Host "skill=learning-bot"
  Write-Host "reason=unknown-argument"
  Write-Host ("unknown=" + ($Rest -join " "))
  Write-Host "valid_params=-Menu | -Questions preset|preflight|clarify|all | -Route <text> | -Resolve <key> | -Install <key> [-OutDir <dir>] [-Force] | -Capacity | -CanRun <model> [-Params <n>] [-Precision INT4|INT8|FP16|FP32]"
  Write-Host "note=unrecognized argument; nothing was executed"
  Write-Host "[/SKILL_RESULT]"
  exit 1
}

function Get-Python {
  # Reuse the content-fetch venv if present, else system python (bot logic is stdlib-only).
  $venvPy = Join-Path $env:USERPROFILE ".openvino\venv-contentfetch\Scripts\python.exe"
  if (Test-Path $venvPy) { return $venvPy }
  # 系统 python 也必须先确认存在 —— 否则 agent 拿到的是 PowerShell 的 CommandNotFoundException，
  # 而不是「该先去装 Python」这个可执行的结论。
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[SKILL_RESULT]"
    Write-Host "status=error"
    Write-Host "skill=learning-bot"
    Write-Host "reason=python-not-found"
    Write-Host "next=openvino-environment-management"
    Write-Host "note=python is not on PATH; run the environment-management skill first"
    Write-Host "[/SKILL_RESULT]"
    exit 1
  }
  return "python"
}

$py = Get-Python

if ($Menu) {
  & $py $Bot --menu
  exit $LASTEXITCODE
}
if ($Questions) {
  & $py $Bot --questions $Questions
  exit $LASTEXITCODE
}
if ($Route) {
  & $py $Bot --route $Route
  exit $LASTEXITCODE
}
if ($Capacity) {
  & $py $Bot --capacity
  exit $LASTEXITCODE
}
if ($CanRun) {
  # -Params 未传时 PowerShell 会给 double 类型默认值 0，不能原样转发（会被当成 0B 模型）。
  $crArgs = @($Bot, "--can-run", $CanRun)
  if ($PSBoundParameters.ContainsKey("Params"))    { $crArgs += @("--params", "$Params") }
  if ($PSBoundParameters.ContainsKey("Precision")) { $crArgs += @("--precision", $Precision) }
  & $py @crArgs
  exit $LASTEXITCODE
}
if ($Resolve) {
  & $py $Bot --resolve $Resolve
  exit $LASTEXITCODE
}
if ($Install) {
  # 备用方案：宿主没预置这个 skill 时，从 release 下载并解压技能包。
  $inArgs = @($Bot, "--install", $Install)
  if ($OutDir) { $inArgs += @("--out-dir", $OutDir) }
  if ($Force)  { $inArgs += "--force" }
  & $py @inArgs
  exit $LASTEXITCODE
}

# Default: show the menu (i.e. "start the Learning Bot").
& $py $Bot --menu
exit $LASTEXITCODE
