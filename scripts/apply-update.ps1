# WorkDaddy Windows 自动更新替换脚本。
# 独立于 daemon 运行：停止 watchdog、替换安装目录、启动新版并验证 API；失败时保留日志并回滚。
# 【防死锁契约】daemon 在 spawn 本脚本前已写入 update/pending.json 且自我退出，watchdog 检测到
# 该标记后不会重启 daemon（防端口抢占竞态）。因此本脚本无论成功、失败还是早期校验不过，
# 退出前都必须：① 写 apply.log 留证 ② 删除 pending.json。任何绕过这两步的退出路径都会把
# 应用留在「daemon 已死、watchdog 永不拉起」的永久卡死状态（issue #51 的死锁根因）。
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][Alias('SrcZip')][string]$SrcPackage,
  [string]$AppDir = '',
  [string]$Port = '47832',
  [string]$LogPath = '',
  [string]$AttemptId = 'unknown',
  [string]$Profile = '__WBS_DEFAULT_PROFILE__'
)

# 【防死锁加固】boundary 加载与路径一致性校验原先位于日志初始化与主 try/finally 之前，
# 失败会静默退出：apply.log 不存在、pending.json 残留，无从排查且造成 watchdog 永久拒启
# （issue #51）。现移入主 try：失败会写入 apply.log 并由 finally 无条件清理 pending.json。
# 权限探针保留在目录创建与日志初始化之前（windows-powershell-boundary 契约要求），
# 但失败时不再 exit 5，改为记录错误延后到主 try 内 throw，确保 transcript 已启动 → 有日志。
$ErrorActionPreference = 'Stop'
$privilegeError = $null
try {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $env:WBSWITCH_PRIVILEGE_MODE = if ($isElevated) { 'elevated' } else { 'standard' }
} catch {
  $privilegeError = "无法确认 PowerShell 权限模式: $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace($Profile) -or $Profile -eq '__WBS_DEFAULT_PROFILE__') { $Profile = 'workbuddy-cn' }
if ($Profile -ne 'workbuddy-ai') { $Profile = 'workbuddy-cn' }
$productName = if ($Profile -eq 'workbuddy-ai') { 'WorkDaddy AI' } else { 'WorkDaddy' }
if ([string]::IsNullOrWhiteSpace($AppDir)) { $AppDir = Join-Path $env:LOCALAPPDATA (Join-Path 'Programs' $productName) }
$dataRoot = Join-Path $env:APPDATA 'WorkDaddy'
$DataDir = if ($Profile -eq 'workbuddy-ai') { Join-Path $dataRoot 'profiles\workbuddy-ai' } else { $dataRoot }
$LogDir = Join-Path $DataDir 'update'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $LogDir 'apply.log' }
$transcriptStarted = $false
try {
  Start-Transcript -Path $LogPath -Append -Force | Out-Null
  $transcriptStarted = $true
} catch {
  # Transcript is diagnostic only; continue with Write-Host if the file cannot be opened.
}

function Write-ApplyLog {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host ("[apply] {0} {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Message)
}

function Stop-ApplyTranscript {
  if ($script:transcriptStarted) {
    try { Stop-Transcript | Out-Null } catch {}
    $script:transcriptStarted = $false
  }
}

function Stop-WatchdogAndPort {
  Stop-VerifiedWorkDaddyLifecycle `
    -DataDir $DataDir `
    -Port ([int]$Port) `
    -ExpectedWatchdogScript (Join-Path $AppDir 'scripts\watchdog.js') `
    -ExpectedDaemonScript (Join-Path $AppDir 'scripts\daemon.js')
}

function Stop-WorkBuddyForUpdate {
  $processName = if ($Profile -eq 'workbuddy-ai') { 'WorkBuddyAI.exe' } else { 'WorkBuddy.exe' }
  $stopped = Stop-VerifiedWorkBuddyProcesses -ProcessName $processName
  if ($stopped -gt 0) { Write-ApplyLog "已停止 $processName 进程数=$stopped，释放安装目录文件锁" }
}

function Rollback-App {
  param([string]$OldDir, [string]$TargetDir)
  Write-ApplyLog "开始回滚旧版本"
  Stop-WatchdogAndPort
  Stop-WorkBuddyForUpdate
  try { if (Test-Path -LiteralPath $TargetDir) { Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
  if (Test-Path -LiteralPath $OldDir) {
    try { Move-Item -LiteralPath $OldDir -Destination $TargetDir -Force -ErrorAction Stop } catch {
      Write-ApplyLog "回滚失败: $($_.Exception.Message)"
    }
  }
  $oldLauncher = Join-Path $TargetDir 'scripts\launcher.cmd'
  $oldLauncherVbs = Join-Path $TargetDir 'scripts\launcher-hidden.vbs'
  try {
    if (Test-Path -LiteralPath $oldLauncherVbs) {
      Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('//nologo "' + $oldLauncherVbs + '"') -WorkingDirectory (Split-Path $oldLauncher) -ErrorAction Stop | Out-Null
    } elseif (Test-Path -LiteralPath $oldLauncher) {
      Start-Process -FilePath $oldLauncher -WorkingDirectory (Split-Path $oldLauncher) -ErrorAction Stop | Out-Null
    }
  } catch {
    Write-ApplyLog "回滚后启动旧 launcher 失败: $($_.Exception.Message)"
  }
}

$oldDir = "$AppDir.old"
$tmpDir = Join-Path $env:TEMP ("workdaddy-update-" + [guid]::NewGuid().ToString('N'))
$backupMade = $false
$isSetupPackage = $false
try {
  Write-ApplyLog "start attempt=$AttemptId src=$SrcPackage dst=$AppDir port=$Port pid=$PID"

  # 【校验 1】权限模式已在脚本顶部探测（契约：探针须在 New-Item/Start-Transcript 前）。
  # 顶部失败时只记录错误，延后到此 throw：transcript 已启动 → 有日志，finally → 清 pending。
  if ($privilegeError) { throw $privilegeError }

  # 【校验 2】加载 Windows 进程身份边界（提供 Test-SameWindowsPath / 停进程等函数）。
  try { . (Join-Path $PSScriptRoot 'windows-process-boundary.ps1') } catch {
    throw "无法加载 Windows 进程身份边界: $($_.Exception.Message)"
  }

  # 【校验 3】路径一致性防误替换（安全网，保留原语义；典型触发：非标准目录安装 +
  # daemon 传入了与脚本实际位置不一致的目标目录）。失败现在会留日志并清标记，
  # 而不是静默崩溃把应用留在死锁态。
  if (-not (Test-SameWindowsPath -Left $PSScriptRoot -Right (Join-Path $AppDir 'scripts'))) {
    throw "更新脚本位置与目标安装目录不一致，拒绝替换（实际脚本: $PSScriptRoot，目标: $AppDir）"
  }

  if (-not (Test-Path -LiteralPath $SrcPackage -PathType Leaf)) { throw "更新包不存在: $SrcPackage" }
  $isSetupPackage = ([IO.Path]::GetExtension($SrcPackage) -ieq '.exe')
  Stop-WatchdogAndPort
  Stop-WorkBuddyForUpdate

  foreach ($launcherPath in @((Join-Path $AppDir 'scripts\launcher.cmd'), (Join-Path $oldDir 'scripts\launcher.cmd'))) {
    if (-not (Release-VerifiedLauncherLock -LauncherPath $launcherPath)) { throw "无法释放 launcher.cmd 文件锁: $launcherPath" }
  }

  $packageName = [IO.Path]::GetFileNameWithoutExtension($SrcPackage)
  $packageVersionMatch = [regex]::Match($packageName, '([0-9]+\.[0-9]+\.[0-9]+)')
  $packageVersion = if ($packageVersionMatch.Success) { $packageVersionMatch.Groups[1].Value } else { '' }
  if ($isSetupPackage) {
    if ([string]::IsNullOrWhiteSpace($packageVersion)) { throw "安装器文件名缺少版本号: $packageName" }
    Write-ApplyLog "artifact inspect setup=$packageName packageVersion=$packageVersion"
    $installer = Start-Process -FilePath $SrcPackage -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WorkingDirectory (Split-Path $SrcPackage) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    Write-ApplyLog "Setup.exe 已退出 code=$($installer.ExitCode)"
    if ($installer.ExitCode -ne 0) { throw "Setup.exe 安装失败 (code=$($installer.ExitCode))" }
    $sourceDaemonVersion = $packageVersion
    $sourceBuildId = ''
  } else {
  if (Test-Path -LiteralPath $oldDir) { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction Stop }
  if (Test-Path -LiteralPath $AppDir) {
    Move-Item -LiteralPath $AppDir -Destination $oldDir -Force -ErrorAction Stop
    $backupMade = $true
  }

  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  Expand-Archive -LiteralPath $SrcPackage -DestinationPath $tmpDir -Force
  $srcRoot = $tmpDir
  if (-not (Test-Path (Join-Path $tmpDir 'scripts\daemon.js'))) {
    $hit = Get-ChildItem -LiteralPath $tmpDir -Recurse -Filter 'daemon.js' -File | Select-Object -First 1
    if ($hit) { $srcRoot = Split-Path $hit.FullName -Parent | Split-Path -Parent }
  }
  foreach ($required in @('scripts\daemon.js', 'scripts\launcher.cmd', 'scripts\win-launcher.js')) {
    if (-not (Test-Path (Join-Path $srcRoot $required) -PathType Leaf)) { throw "更新包缺少 $required" }
  }
  $sourceDaemonText = Get-Content -LiteralPath (Join-Path $srcRoot 'scripts\daemon.js') -Raw
  $sourceDaemonMatch = [regex]::Match($sourceDaemonText, "const DAEMON_VERSION = '([^']+)'")
  $sourceDaemonVersion = if ($sourceDaemonMatch.Success) { $sourceDaemonMatch.Groups[1].Value } else { '' }
  $sourceBuildMatch = [regex]::Match($sourceDaemonText, "const DAEMON_BUILD_ID = '([^']+)'")
  $sourceBuildId = if ($sourceBuildMatch.Success) { $sourceBuildMatch.Groups[1].Value } else { '' }
  $packageName = [IO.Path]::GetFileNameWithoutExtension($SrcPackage)
  $packageVersionMatch = [regex]::Match($packageName, '([0-9]+\.[0-9]+\.[0-9]+)')
  $packageVersion = if ($packageVersionMatch.Success) { $packageVersionMatch.Groups[1].Value } else { '' }
  Write-ApplyLog "artifact inspect package=$packageName packageVersion=$packageVersion daemonVersion=$sourceDaemonVersion"
  if ([string]::IsNullOrWhiteSpace($sourceDaemonVersion)) { throw '更新包 daemon.js 缺少 DAEMON_VERSION' }
  if ([string]::IsNullOrWhiteSpace($sourceBuildId)) { throw '更新包 daemon.js 缺少 DAEMON_BUILD_ID' }
  if (-not [string]::IsNullOrWhiteSpace($packageVersion) -and $sourceDaemonVersion -ne $packageVersion) {
    throw "更新包内部 daemon 版本 $sourceDaemonVersion 与文件目标版本 $packageVersion 不一致"
  }

  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  & robocopy $srcRoot $AppDir /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  $rc = $LASTEXITCODE
  Write-ApplyLog "robocopy code=$rc"
  if ($rc -ge 8) { throw "robocopy 复制失败 (code=$rc)" }
  }

  $launcher = Join-Path $AppDir 'scripts\launcher.cmd'
  $launcherVbs = Join-Path $AppDir 'scripts\launcher-hidden.vbs'
  if (Test-Path -LiteralPath $launcherVbs) {
    $started = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('//nologo "' + $launcherVbs + '"') -WorkingDirectory (Split-Path $launcher) -PassThru -ErrorAction Stop
  } else {
    $started = Start-Process -FilePath $launcher -WorkingDirectory (Split-Path $launcher) -PassThru -ErrorAction Stop
  }
  Write-ApplyLog "已启动新版 launcher pid=$($started.Id)，等待 daemon"
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    try {
      $status = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/status" -f $Port) -Method Get -TimeoutSec 2
      [void](Assert-DaemonStatusIdentity `
        -Status $status `
        -Port ([int]$Port) `
        -ExpectedProfile $Profile `
        -ExpectedVersion $sourceDaemonVersion `
        -ExpectedDaemonScript (Join-Path $AppDir 'scripts\daemon.js') `
        -ExpectedBuildId $sourceBuildId)
      if ($status.version) { $ready = $true; Write-ApplyLog "新版 daemon 已就绪 version=$($status.version)"; break }
    } catch {}
    Start-Sleep -Seconds 1
  }
  if (-not $ready) { throw '新版 daemon 在 60 秒内未就绪' }
  $runningVersion = [string]$status.version
  Write-ApplyLog "running daemon version=$runningVersion expected=$sourceDaemonVersion"
  if ($runningVersion -ne $sourceDaemonVersion) {
    throw "新版 daemon 实际版本 $runningVersion 与包内 daemon 版本 $sourceDaemonVersion 不一致"
  }

  if (Test-Path -LiteralPath $oldDir) {
    Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-ApplyLog "done attempt=$AttemptId"
  Stop-ApplyTranscript
  exit 0
} catch {
  Write-ApplyLog "FAILED attempt=$AttemptId error=$($_.Exception.Message)"
  if ($backupMade) { Rollback-App -OldDir $oldDir -TargetDir $AppDir }
  Stop-ApplyTranscript
  exit 1
} finally {
  # 【防死锁契约 · 兜底】本脚本是唯一的更新执行者：无论走到哪一步退出（含早期校验失败），
  # 更新流程都已结束，pending.json 必须删除，否则 watchdog 将永久拒绝重启 daemon。
  # 原实现以 $lifecycleValidated 门控本清理，导致「停止 watchdog 之前」的任何失败
  # （路径不一致、包缺失等）都会残留标记 → issue #51 永久卡死。现改为无条件清理。
  try { if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
  try { Remove-Item -LiteralPath (Join-Path $LogDir 'pending.json') -Force -ErrorAction SilentlyContinue } catch {}
}
