# 워커 로그가 외부 읽기 도구에 의해 중간부터 막히지 않고, 시작 시 이미 잠겨 있으면
# 복구 로그로 전환하며, 두 로그가 모두 막힌 경우 조용히 진행하지 않는지 검사합니다.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'source_test_helpers.ps1')
$root = Split-Path -Parent $PSScriptRoot
$workerPath = Join-Path $root 'mabinogi_run_once.ps1'
$guiPath = Join-Path $root 'mabinogi_gui.ps1'
Invoke-Expression ((Get-SourceFunctionDefinitions -Path $workerPath -Names @(
      'Close-RunLogWriter',
      'Open-RunLogWriter',
      'Initialize-RunLog',
      'Write-RunLog'
    )) -join "`n")
Invoke-Expression ((Get-SourceFunctionDefinitions -Path $guiPath -Names @('Move-WorkerLogToArchive')) -join "`n")

$fails = 0
function Check-Equal {
  param([string]$Name, $Actual, $Expected)
  if ($Actual -eq $Expected) { "OK   $Name" }
  else { "FAIL $Name (actual=$Actual expected=$Expected)"; $script:fails++ }
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("honeynogi_run_log_{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$logPath = Join-Path $tempDir 'mabinogi_run_once.log'
$logRecoveryPath = Join-Path $tempDir 'mabinogi_run_once.recovery.log'
$script:runLogWriter = $null
$script:runLogTargetPath = $null
$script:runLogUsingRecovery = $false
$script:runLogHeader = $null
$script:runLogOpenAttempts = 1
$script:runLogRetryDelayMs = 0
$blocker = $null
$recoveryBlocker = $null
$archiveBlocker = $null

try {
  Initialize-RunLog -Reset
  $denyWriterOpened = $false
  try {
    $denyWriter = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $denyWriterOpened = $true
    $denyWriter.Dispose()
  } catch {}
  Check-Equal '지속 쓰기 스트림이 후발 읽기 도구의 쓰기 차단 열기를 거부' $denyWriterOpened $false

  Write-RunLog '[테스트] 기본 로그 기록'
  Close-RunLogWriter
  $primaryText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
  Check-Equal '기본 로그에 헤더와 실행 줄 기록' `
    ($primaryText.Contains('자동화 로그 (시작') -and $primaryText.Contains('[테스트] 기본 로그 기록')) $true
  Check-Equal '정상 기록에서는 복구 로그 미생성' (Test-Path -LiteralPath $logRecoveryPath) $false

  [IO.File]::WriteAllText($logPath, '잠금 전 기존 내용', (New-Object Text.UTF8Encoding($true)))
  $blocker = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  Initialize-RunLog -Reset
  Write-RunLog '[테스트] 복구 로그 기록'
  Close-RunLogWriter
  Check-Equal '시작 시 기본 로그가 잠기면 복구 로그 사용' $script:runLogUsingRecovery $true
  Check-Equal '잠긴 기본 로그의 기존 내용은 훼손하지 않음' `
    ((Get-Content -LiteralPath $logPath -Raw -Encoding UTF8).Contains('잠금 전 기존 내용')) $true
  $recoveryText = Get-Content -LiteralPath $logRecoveryPath -Raw -Encoding UTF8
  Check-Equal '복구 로그에 전환 경고 기록' $recoveryText.Contains('기본 로그 파일이 다른 프로그램에 잠겨 복구 로그') $true
  Check-Equal '복구 로그에 누락 없이 실행 줄 기록' $recoveryText.Contains('[테스트] 복구 로그 기록') $true

  $recoveryBlocker = [IO.File]::Open($logRecoveryPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $bothLockedThrew = $false
  try { Initialize-RunLog -Reset } catch { $bothLockedThrew = $true }
  Check-Equal '기본·복구 로그가 모두 잠기면 조용히 진행하지 않고 오류' $bothLockedThrew $true

  $scriptRoot = Join-Path $tempDir 'archive_app'
  $archiveLogDir = Join-Path $scriptRoot 'Log'
  New-Item -ItemType Directory -Path $archiveLogDir | Out-Null
  $archiveSource = Join-Path $archiveLogDir 'mabinogi_run_once.recovery.log'
  [IO.File]::WriteAllText($archiveSource, "복구 로그`r`n", (New-Object Text.UTF8Encoding($true)))
  $archiveOffset = Move-WorkerLogToArchive -Path $archiveSource -Suffix '_recovery'
  $archivedRecovery = @(Get-ChildItem -LiteralPath $archiveLogDir -Filter 'run_*_recovery.log')
  Check-Equal '복구 로그 보관 성공 시 오프셋 초기화' $archiveOffset ([long]0)
  Check-Equal '복구 로그를 구분되는 지난 회차 이름으로 보관' $archivedRecovery.Count 1

  $lockedArchiveSource = Join-Path $archiveLogDir 'mabinogi_run_once.log'
  [IO.File]::WriteAllText($lockedArchiveSource, '잠긴 과거 로그', (New-Object Text.UTF8Encoding($true)))
  $lockedArchiveLength = (Get-Item -LiteralPath $lockedArchiveSource).Length
  $archiveBlocker = [IO.File]::Open($lockedArchiveSource, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $lockedOffset = Move-WorkerLogToArchive -Path $lockedArchiveSource
  Check-Equal '보관 파일이 잠기면 기존 길이부터 읽도록 오프셋 유지' $lockedOffset $lockedArchiveLength
} finally {
  Close-RunLogWriter
  if ($null -ne $blocker) { $blocker.Dispose() }
  if ($null -ne $recoveryBlocker) { $recoveryBlocker.Dispose() }
  if ($null -ne $archiveBlocker) { $archiveBlocker.Dispose() }
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

$guiRaw = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
$workerRaw = Get-Content -LiteralPath $workerPath -Raw -Encoding UTF8
Check-Equal '오류 세트가 기본 경로가 아닌 실제 활성 로그를 복사' `
  ($workerRaw.Contains('Copy-Item -LiteralPath $script:runLogTargetPath -Destination $diagLog -Force')) $true
Check-Equal 'GUI가 복구 로그를 별도 오프셋으로 실시간 읽음' `
  ($guiRaw.Contains('Read-NewLogLines -Path $workerRecoveryLog -Offset ([ref]$script:recoveryLogOffset)')) $true
Check-Equal '다음 회차 시작 전 복구 로그도 별도 이름으로 보관' `
  ($guiRaw.Contains("Move-WorkerLogToArchive -Path `$workerRecoveryLog -Suffix '_recovery'")) $true

exit $fails
