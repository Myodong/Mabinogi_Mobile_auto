param(
  [ValidateSet('Menu', 'Infinite', 'Count')]
  [string]$Mode = 'Menu',

  [ValidateRange(0, 9999)]
  [int]$Count = 0
)

$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# [레거시 안내] 이 콘솔 컨트롤러는 구버전 실행 방식입니다.
# 현재 권장 방식은 HoneyNogi.exe(GUI 컨트롤 패널)이며, 이 파일은 exe 에 포함되지 않습니다.
# 주의: GUI(exe)가 실행 중일 때 이 컨트롤러를 함께 실행하면 시작 시 프로세스 정리 단계에서
#       서로의 워커를 강제 종료할 수 있습니다. 한 가지 방식만 사용하세요.
# ─────────────────────────────────────────────────────────────────────────────
$workerScript = Join-Path $PSScriptRoot 'mabinogi_run_once.ps1'
$logDir = Join-Path $PSScriptRoot 'Log'
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir | Out-Null
}
$workerLog = Join-Path $logDir 'mabinogi_run_once.log'
$controllerLog = Join-Path $logDir 'mabinogi_controller.log'

# config.json 에서 기본 반복 횟수와 RDP 자동 전환 설정을 읽습니다.
$defaultRepeatCount = 2
$autoConsoleRedirect = $true
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path -LiteralPath $configPath) {
  try {
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $repeatProp = $cfg.PSObject.Properties['repeat']
    if ($repeatProp -and $repeatProp.Value.PSObject.Properties['defaultCount']) {
      $val = [int]$repeatProp.Value.defaultCount
      if ($val -ge 1 -and $val -le 9999) { $defaultRepeatCount = $val }
    }
    $rdpProp = $cfg.PSObject.Properties['rdp']
    if ($rdpProp -and $rdpProp.Value.PSObject.Properties['autoConsoleRedirect']) {
      $autoConsoleRedirect = [bool]$rdpProp.Value.autoConsoleRedirect
    }
  } catch { }
}

function Write-ControllerStatus {
  param(
    [string]$Message,
    [ConsoleColor]$Color = [ConsoleColor]::Gray
  )

  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
  # 로그를 읽는 다른 프로세스와 겹쳐도 죽지 않도록 짧게 재시도합니다.
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      Add-Content -LiteralPath $controllerLog -Value $line -Encoding UTF8 -ErrorAction Stop
      break
    } catch {
      Start-Sleep -Milliseconds 50
    }
  }
  Write-Host $line -ForegroundColor $Color
}

function Invoke-StartBeep {
  try { [Console]::Beep(880, 140) } catch {}
}

function Invoke-StopBeep {
  try {
    [Console]::Beep(660, 120)
    Start-Sleep -Milliseconds 80
    [Console]::Beep(660, 120)
  } catch {}
}

function Invoke-ExitBeep {
  try {
    [Console]::Beep(440, 100)
    Start-Sleep -Milliseconds 60
    [Console]::Beep(440, 100)
    Start-Sleep -Milliseconds 60
    [Console]::Beep(440, 100)
  } catch {}
}

if ($Mode -eq 'Menu') {
  $Host.UI.RawUI.WindowTitle = '꿀비노기 모드 선택'

  while ($true) {
    Clear-Host
    Write-Host '마비노기 모바일 자동화' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. F12 무한 반복' -ForegroundColor White
    Write-Host '  2. 횟수 지정 반복' -ForegroundColor White
    Write-Host '  0. 종료' -ForegroundColor DarkGray
    Write-Host ''
    $choice = Read-Host '실행할 모드 번호를 입력해주세요'

    if ($choice -eq '1') {
      $Mode = 'Infinite'
      $Count = 0
      break
    }

    if ($choice -eq '2') {
      while ($true) {
        $countText = Read-Host "반복할 횟수를 입력하세요 (1~9999, 그냥 Enter=기본값 $defaultRepeatCount)"
        if ([string]::IsNullOrWhiteSpace($countText)) {
          $Mode = 'Count'
          $Count = $defaultRepeatCount
          break
        }
        $parsedCount = 0
        if ([int]::TryParse($countText, [ref]$parsedCount) -and $parsedCount -ge 1 -and $parsedCount -le 9999) {
          $Mode = 'Count'
          $Count = $parsedCount
          break
        }
        Write-Host '1부터 9999 사이의 숫자를 입력하세요.' -ForegroundColor Red
      }
      break
    }

    if ($choice -eq '0') {
      exit
    }

    Write-Host '1, 2 또는 0을 입력하세요.' -ForegroundColor Red
    Start-Sleep -Seconds 1
  }
}

if ($Mode -eq 'Count' -and $Count -le 0) {
  throw '횟수 지정 모드에는 1 이상의 반복 횟수가 필요합니다.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $PSCommandPath + '"'),
    '-Mode', $Mode
  )
  if ($Mode -eq 'Count') {
    $arguments += @('-Count', $Count)
  }

  Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Normal -ArgumentList $arguments
  exit
}

if (-not (Test-Path -LiteralPath $workerScript)) {
  throw "1회 실행 스크립트를 찾지 못했습니다: $workerScript"
}

for ($attempt = 0; $attempt -lt 20; $attempt++) {
  try {
    Set-Content -LiteralPath $controllerLog -Value "$(Get-Date -Format o) START" -Encoding UTF8 -ErrorAction Stop
    break
  } catch {
    Start-Sleep -Milliseconds 50
  }
}
$Host.UI.RawUI.WindowTitle = '마비노기 모바일 반복 컨트롤러'

# ===== 기존 자동화 프로세스 정리 =====
# 실행기를 새로 켜면 이미 떠 있는 컨트롤러/워커를 모두 종료하고 새로 시작합니다.
# (핫키가 안 듣는 고아 워커, 중복 컨트롤러 등을 한 번에 정리)
try {
  $automationPattern = 'mabinogi_controller\.ps1|mabinogi_run_once\.ps1'
  $existingProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $automationPattern })
  foreach ($existingProcess in $existingProcesses) {
    try {
      Stop-Process -Id $existingProcess.ProcessId -Force -ErrorAction Stop
      Write-ControllerStatus "기존 자동화 프로세스(PID $($existingProcess.ProcessId))를 종료하고 새로 시작합니다." Yellow
    } catch {
      Write-ControllerStatus "기존 프로세스(PID $($existingProcess.ProcessId)) 종료 실패: $($_.Exception.Message)" Red
    }
  }
  if ($existingProcesses.Count -gt 0) {
    Start-Sleep -Milliseconds 500
  }
} catch {
  Write-ControllerStatus "기존 프로세스 확인 실패(무시하고 진행): $($_.Exception.Message)" Yellow
}

# ===== RDP 자동 전환 예약 작업 관리 =====
# config.json 의 rdp.autoConsoleRedirect 가 true(기본)면, RDP 연결이 끊길 때
# 자동으로 화면을 본체 모니터로 넘기는 예약 작업을 설치합니다.
# 설치 후에는 RDP 창을 그냥 닫아도 자동화가 계속 돕니다.
# (이미 관리자 권한으로 실행 중이므로 추가 승인 없이 조용히 처리됩니다)
try {
  $redirectTaskName = 'MabinogiRDPToConsole'
  $redirectScript = Join-Path $PSScriptRoot 'rdp_redirect_console.ps1'
  $existingTask = Get-ScheduledTask -TaskName $redirectTaskName -ErrorAction SilentlyContinue

  if ($autoConsoleRedirect -and -not $existingTask -and (Test-Path -LiteralPath $redirectScript)) {
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
      '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $redirectScript + '"')
    $eventChannel = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
    $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $taskTrigger = New-CimInstance -CimClass $triggerClass -ClientOnly
    $taskTrigger.Enabled = $true
    $taskTrigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"$eventChannel`"><Select Path=`"$eventChannel`">*[System[(EventID=24)]]</Select></Query></QueryList>"
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $redirectTaskName -Action $taskAction -Trigger $taskTrigger `
      -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
    Write-Host 'RDP 자동 전환이 설치됐습니다. 이제 RDP 창을 닫아도 자동화가 계속 돕니다.' -ForegroundColor Green
  } elseif (-not $autoConsoleRedirect -and $existingTask) {
    Unregister-ScheduledTask -TaskName $redirectTaskName -Confirm:$false
    Write-Host 'RDP 자동 전환을 제거했습니다 (config.json 설정에 따름).' -ForegroundColor Yellow
  }
} catch {
  Write-Host "RDP 자동 전환 설정을 적용하지 못했습니다: $($_.Exception.Message)" -ForegroundColor Yellow
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MabinogiControllerKeys {
  [DllImport("user32.dll")]
  public static extern short GetAsyncKeyState(int virtualKey);
}
'@

$script:stopRequested = $false
$script:exitRequested = $false
$script:activeWorker = $null

function Get-ControllerHotkey {
  $f12State = [MabinogiControllerKeys]::GetAsyncKeyState(0x7B)
  if (($f12State -band 0x0001) -eq 0) {
    return $null
  }

  $controlState = [MabinogiControllerKeys]::GetAsyncKeyState(0x11)
  while (([MabinogiControllerKeys]::GetAsyncKeyState(0x7B) -band 0x8000) -ne 0) {
    Start-Sleep -Milliseconds 30
  }

  if (($controlState -band 0x8000) -ne 0) {
    return 'Exit'
  }
  return 'Toggle'
}

function Show-WorkerLogUpdates {
  param([ref]$SeenLineCount)

  if (-not (Test-Path -LiteralPath $workerLog)) {
    return
  }

  try {
    $lines = @(Get-Content -LiteralPath $workerLog -ErrorAction Stop)
    if ($lines.Count -le $SeenLineCount.Value) {
      return
    }

    for ($index = $SeenLineCount.Value; $index -lt $lines.Count; $index++) {
      Write-Host "  $($lines[$index])" -ForegroundColor DarkGray
    }
    $SeenLineCount.Value = $lines.Count
  } catch {
    # 작업 스크립트가 로그를 쓰는 순간의 일시적인 읽기 실패는 다음 폴링에서 재시도합니다.
  }
}

function Request-SafeStop {
  if (-not $script:stopRequested) {
    $script:stopRequested = $true
    Write-ControllerStatus 'F12 감지: 현재 1회 사이클을 마치고 안전 중지합니다.' Yellow
    Invoke-StopBeep
  }
}

function Request-ImmediateExit {
  $script:exitRequested = $true
  Write-ControllerStatus 'Ctrl+F12 감지: 컨트롤러를 즉시 종료합니다.' Red

  if ($script:activeWorker -and -not $script:activeWorker.HasExited) {
    try {
      $script:activeWorker.Kill()
      $script:activeWorker.WaitForExit()
    } catch {}
  }
  Invoke-ExitBeep
}

function Invoke-OneCycle {
  param([int]$CycleNumber)

  Remove-Item -LiteralPath $workerLog -Force -ErrorAction SilentlyContinue
  $workerArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $workerScript + '"')
  )

  Write-ControllerStatus "${CycleNumber}회차 시작" Cyan
  $script:activeWorker = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
    -ArgumentList $workerArguments -PassThru
  $seenLineCount = 0

  while (-not $script:activeWorker.HasExited) {
    Show-WorkerLogUpdates -SeenLineCount ([ref]$seenLineCount)

    $hotkey = Get-ControllerHotkey
    if ($hotkey -eq 'Exit') {
      Request-ImmediateExit
      return $false
    }
    if ($hotkey -eq 'Toggle') {
      Request-SafeStop
    }

    Start-Sleep -Milliseconds 150
  }

  $script:activeWorker.WaitForExit()
  Show-WorkerLogUpdates -SeenLineCount ([ref]$seenLineCount)
  $exitCode = $script:activeWorker.ExitCode
  $script:activeWorker = $null

  # 워커 종료 코드 계약: 0=회차 완료 / 2=중복 실행 / 3=미개발 구간 정지 / 4=조건 충족 정지
  # (은동전 소진 등) / 10=준비 실행(화면 복귀만 수행 - 회차로 세지 않음) / 그 외=오류
  if ($exitCode -eq 10) {
    Write-ControllerStatus "${CycleNumber}회차: 화면 복귀(준비 실행)만 수행 - 회차로 세지 않고 이어서 진행합니다." Cyan
    return 'prepared'
  }
  if ($exitCode -eq 3 -or $exitCode -eq 4) {
    Write-ControllerStatus "${CycleNumber}회차: 조건에 따른 정상 정지(코드 $exitCode - 자세한 내용은 로그 참고). 반복을 마칩니다." Cyan
    $script:stopRequested = $true
    return $false
  }
  if ($exitCode -eq 2) {
    Write-ControllerStatus "${CycleNumber}회차: 다른 자동화 인스턴스가 이미 실행 중(코드 2)이라 시작하지 못했습니다. 반복을 중단합니다." Red
    $script:stopRequested = $true
    return $false
  }
  if ($exitCode -ne 0) {
    Write-ControllerStatus "${CycleNumber}회차 오류 종료(코드 $exitCode). 반복을 중단합니다." Red
    $script:stopRequested = $true
    return $false
  }

  Write-ControllerStatus "${CycleNumber}회차 완료" Green
  return $true
}

function Invoke-CycleLoop {
  param([int]$TargetCount = 0)

  $script:stopRequested = $false
  $completed = 0
  $preparedStreak = 0   # 연속 '준비 실행'(코드 10) 횟수 - 화면 오판으로 인한 무한 준비 루프 방지
  Invoke-StartBeep

  while (-not $script:exitRequested) {
    if ($TargetCount -gt 0 -and $completed -ge $TargetCount) {
      break
    }

    $cycleNumber = $completed + 1
    $success = Invoke-OneCycle -CycleNumber $cycleNumber
    if ($script:exitRequested) {
      break
    }
    # 문자열을 왼쪽에 두어야 정확합니다: $true -eq 'prepared' 는 PS 형 변환 때문에 참이 됩니다
    if ('prepared' -eq $success) {
      # 화면 복귀만 수행한 준비 실행: 회차로 세지 않고 같은 번호로 본 회차를 진행합니다.
      # 단, continue 가 아래의 안전 중지/핫키 검사를 건너뛰므로 여기서 직접 확인하고,
      # 화면 오판으로 준비 실행만 반복되는 상황에 대비해 연속 횟수 상한을 둡니다.
      if ($script:stopRequested) { break }
      $preparedStreak++
      if ($preparedStreak -ge 3) {
        Write-ControllerStatus '준비 실행(화면 복귀)이 3회 연속 반복됩니다 - 게임 화면 상태를 확인해 주세요. 반복을 중단합니다.' Red
        break
      }
      continue
    }
    $preparedStreak = 0
    if (-not $success) {
      break
    }

    $completed++
    if ($script:stopRequested) {
      break
    }

    $hotkey = Get-ControllerHotkey
    if ($hotkey -eq 'Exit') {
      Request-ImmediateExit
      break
    }
    if ($hotkey -eq 'Toggle') {
      Request-SafeStop
      break
    }
  }

  return $completed
}

Write-Host ''
Write-Host '마비노기 모바일 반복 컨트롤러' -ForegroundColor Cyan
Write-Host '  F12       : 무한 반복 시작 / 현재 사이클 완료 후 안전 중지' -ForegroundColor White
Write-Host '  Ctrl+F12  : 컨트롤러 즉시 종료' -ForegroundColor White
Write-Host '  창을 닫아도 컨트롤러가 종료됩니다.' -ForegroundColor DarkGray
Write-Host ''

if ($Mode -eq 'Count') {
  Write-ControllerStatus "횟수 지정 모드: 총 ${Count}회 실행" Cyan
  $completedCount = Invoke-CycleLoop -TargetCount $Count

  if (-not $script:exitRequested) {
    if ($completedCount -eq $Count) {
      Write-ControllerStatus "지정한 ${Count}회 실행을 모두 완료했습니다." Green
    } elseif ($script:stopRequested) {
      Write-ControllerStatus "안전 중지 완료: ${completedCount}/${Count}회 완료" Yellow
    }
    Write-Host '5초 후 컨트롤러 창을 닫습니다.' -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
  }
  exit
}

while (-not $script:exitRequested) {
  $script:stopRequested = $false
  Write-ControllerStatus '대기 중: F12를 누르면 무한 반복을 시작합니다.' DarkCyan

  $startRequested = $false
  while (-not $startRequested -and -not $script:exitRequested) {
    $hotkey = Get-ControllerHotkey
    if ($hotkey -eq 'Exit') {
      Request-ImmediateExit
      break
    }
    if ($hotkey -eq 'Toggle') {
      $startRequested = $true
      Write-ControllerStatus 'F12 감지: 무한 반복을 시작합니다.' Green
      break
    }
    Start-Sleep -Milliseconds 100
  }

  if ($startRequested -and -not $script:exitRequested) {
    $completedCount = Invoke-CycleLoop
    if (-not $script:exitRequested) {
      Write-ControllerStatus "안전 중지 완료: 이번 실행에서 ${completedCount}회 완료" Yellow
    }
  }
}

Write-ControllerStatus '컨트롤러가 종료됐습니다.' DarkGray
