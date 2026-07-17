# ============================================================
#  꿀비노기 (마비노기 모바일 자동화) - 컨트롤 패널 (GUI)
#  mabinogi_UI실행기.cmd 로 실행하세요.
# ============================================================
$ErrorActionPreference = 'Stop'

# ----- 관리자 권한 확인 (게임 입력에 필요) -----
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
  exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----- 작업표시줄 아이콘/그룹 분리 -----
# 이 창은 powershell.exe 안에서 뜨기 때문에 기본으로는 작업표시줄에서 PowerShell 아이콘으로
# 묶입니다. 창을 만들기 전에 전용 AppUserModelID 를 부여하면 작업표시줄이 이 창을 독립 앱으로
# 취급해 창 아이콘(꿀단지, $form.Icon)을 그대로 보여줍니다.
try {
  Add-Type -Namespace Win32 -Name TaskbarAppId -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@
  [Win32.TaskbarAppId]::SetCurrentProcessExplicitAppUserModelID('HoneyNogi.ControlPanel') | Out-Null
} catch { }

# ----- 중복 실행 방지 (워커와 동일한 방식의 전역 뮤텍스) -----
# 컨트롤 패널이 여러 개 뜨면 [시작] 시 서로의 워커를 '기존 프로세스'로 종료시키고
# 설정 저장도 서로 덮어쓰므로, 두 번째 인스턴스는 안내 후 스스로 종료합니다.
$script:guiMutex = New-Object System.Threading.Mutex($false, 'Global\HoneyNogiGui')
$guiMutexAcquired = $false
try {
  $guiMutexAcquired = $script:guiMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  # 이전 GUI가 강제 종료되어 뮤텍스가 버려진 경우: 이 인스턴스가 소유권을 이어받음
  $guiMutexAcquired = $true
}
if (-not $guiMutexAcquired) {
  [System.Windows.Forms.MessageBox]::Show(
    '컨트롤 패널이 이미 실행 중입니다. 기존 창을 사용해 주세요.' + [Environment]::NewLine +
    '(기존 창이 안 보이면 작업 관리자에서 powershell.exe 를 확인하세요)',
    '꿀비노기', [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
  exit
}

# 화면 꺼짐 방지용 API (자동화 실행 중에만 화면 유지 신호를 켭니다)
Add-Type -Namespace Win32 -Name PowerState -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
# 입력 상태 정리용 API: 워커를 즉시 종료(Kill)하는 순간이 워커의 키/마우스 '누름'과 '뗌'
# 사이일 수 있습니다(ALT 약 160ms, 좌클릭 약 100ms 간격). 주입된 눌림 상태는 프로세스가
# 죽어도 풀리지 않아 이후 수동 조작이 ALT+클릭처럼 동작하므로, Kill 후 강제로 떼 줍니다.
Add-Type -Namespace Win32 -Name InputRelease -MemberDefinition @'
[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")]
public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
'@
# 전역 단축키 감지용 API: 게임 창에 포커스가 있어도 F9/F10을 인식하기 위해
# 키보드 상태를 직접 읽습니다 (레거시 컨트롤러의 F12와 같은 방식).
Add-Type -Namespace Win32 -Name HotkeyPoll -MemberDefinition @'
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
'@

function Apply-RecommendedWindowSize {
  # 게임 창을 '권장 크기'(화면에 들어가면 1908x1076, 아니면 1272x717)로 즉시 변경합니다.
  # GUI 프로세스는 DPI 가상 좌표를 쓰고 워커는 실제 픽셀을 쓰므로, 좌표 불일치를 피하기 위해
  # DPI 인식 헬퍼 스크립트를 별도 프로세스로 실행합니다 (워커의 계산과 완전히 동일).
  $helper = Join-Path $scriptRoot 'resize_to_recommended.ps1'
  $lines = @(
    "`$ErrorActionPreference = 'SilentlyContinue'",
    "`$md = '[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }' +",
    " '[DllImport(`"user32.dll`")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);' +",
    " '[DllImport(`"user32.dll`")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool bRepaint);' +",
    " '[DllImport(`"user32.dll`")] public static extern int GetSystemMetrics(int nIndex);' +",
    " '[DllImport(`"user32.dll`")] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref RECT pvParam, uint fWinIni);' +",
    " '[DllImport(`"user32.dll`")] public static extern bool SetProcessDPIAware();'",
    "Add-Type -Namespace RW -Name Win -MemberDefinition `$md",
    "[RW.Win]::SetProcessDPIAware() | Out-Null",
    "`$p = Get-Process -Name 'MabinogiMobile' -ErrorAction SilentlyContinue | Where-Object { `$_.MainWindowHandle -ne 0 } | Select-Object -First 1",
    "if (-not `$p) { exit }",
    "# 작업 영역(작업표시줄 제외) 기준 - 창이 작업표시줄과 겹치면 하단 감지/클릭이 막힘",
    "`$wa = New-Object RW.Win+RECT",
    "if ([RW.Win]::SystemParametersInfo(0x0030, 0, [ref]`$wa, 0)) { `$wx=`$wa.Left; `$wy=`$wa.Top; `$ww=`$wa.Right-`$wa.Left; `$wh=`$wa.Bottom-`$wa.Top }",
    "else { `$wx=0; `$wy=0; `$ww=[RW.Win]::GetSystemMetrics(0); `$wh=[RW.Win]::GetSystemMetrics(1) }",
    "if (`$ww -ge 2100 -and `$wh -ge 1150) { `$tw = 1908; `$th = 1076 } else { `$tw = 1272; `$th = 717 }",
    "`$r = New-Object RW.Win+RECT",
    "[RW.Win]::GetWindowRect(`$p.MainWindowHandle, [ref]`$r) | Out-Null",
    "`$tx = [Math]::Min([Math]::Max(`$r.Left, `$wx), [Math]::Max(`$wx + `$ww - `$tw, `$wx))",
    "`$ty = [Math]::Min([Math]::Max(`$r.Top, `$wy), [Math]::Max(`$wy + `$wh - `$th, `$wy))",
    "[RW.Win]::MoveWindow(`$p.MainWindowHandle, `$tx, `$ty, `$tw, `$th, `$true) | Out-Null"
  )
  try {
    Set-Content -LiteralPath $helper -Value ($lines -join "`r`n") -Encoding UTF8
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"'))
    Add-GuiLog '[안내] 게임 창을 권장 크기로 변경합니다 (OCR 인식 최적 - 1908x1076 또는 1272x717)'
  } catch {
    Add-GuiLog "[경고] 권장 창 크기 적용 실패: $($_.Exception.Message)"
  }
}

function Release-StuckInput {
  # 워커 강제 종료 직후 호출: 워커가 누를 수 있는 키들과 마우스 왼쪽 버튼을 '뗌' 상태로 되돌립니다.
  # (Kill 시점이 키 '누름-뗌' 사이면 그 키가 눌린 채 남기 때문. 키업만 보내므로
  #  이미 떼어져 있는 키에는 아무 효과가 없는 안전한 호출입니다.)
  try {
    # 기본 해제 목록: ALT(Focus-Game), Space(자동출발/부활 재개), B(음식), R(부활)
    $releaseKeys = @(0x12, 32, 66, 82)
    # config에 사용자 지정 키(afterEntry.keys / revive)가 있으면 그 키들도 포함합니다
    try {
      $cfgNow = Read-Config
      if ($cfgNow) {
        if ($cfgNow.PSObject.Properties['afterEntry'] -and $cfgNow.afterEntry.PSObject.Properties['keys']) {
          foreach ($entry in @($cfgNow.afterEntry.keys)) {
            if ($entry.PSObject.Properties['key']) { $releaseKeys += [int]$entry.key }
          }
        }
        if ($cfgNow.PSObject.Properties['revive']) {
          if ($cfgNow.revive.PSObject.Properties['key']) { $releaseKeys += [int]$cfgNow.revive.key }
          if ($cfgNow.revive.PSObject.Properties['resumeKey']) { $releaseKeys += [int]$cfgNow.revive.resumeKey }
        }
      }
    } catch { }
    foreach ($vk in ($releaseKeys | Sort-Object -Unique)) {
      if ($vk -gt 0 -and $vk -le 255) {
        [Win32.InputRelease]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)   # KEYEVENTF_KEYUP
      }
    }
    [Win32.InputRelease]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)       # 좌클릭 up (MOUSEEVENTF_LEFTUP)
  } catch { }
}
# ES_CONTINUOUS(0x80000000) | ES_SYSTEM_REQUIRED(0x1) | ES_DISPLAY_REQUIRED(0x2)
$script:esKeepAwake = [uint32]2147483651   # 0x80000003
$script:esRelease   = [uint32]2147483648   # 0x80000000 (ES_CONTINUOUS only)

# 앱 버전 (단일 관리 지점): 여기만 올리면 GUI 제목·로그·exe 파일 속성(빌드 시 자동 추출)에
# 모두 반영됩니다. 파일명은 HoneyNogi.exe 로 고정 - 업데이트는 늘 '덮어쓰기 한 번'.
# ※ 좌표 버전(coordsVersion)과는 별개입니다 (그쪽은 화면 좌표 변경 시에만 올림)
$appVersion = '1.0.0'

$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot 'config.json'
$workerScript = Join-Path $scriptRoot 'mabinogi_run_once.ps1'
$workerLog = Join-Path $scriptRoot 'Log\mabinogi_run_once.log'
# 안전 중지 신호 파일: GUI가 만들면 워커가 '던전 밖(HUD) 확인' 시점에서 회차를 조기 종료합니다.
$safeStopFlag = Join-Path $scriptRoot 'Log\safe_stop.flag'
$redirectScript = Join-Path $scriptRoot 'rdp_redirect_console.ps1'

# ----- 설정 읽기/쓰기 -----
function Read-Config {
  # 파싱 실패 원인을 기억해 두어, 사용자에게 '어디가 잘못됐는지'까지 안내할 수 있게 합니다.
  $script:configReadError = $null
  if (Test-Path -LiteralPath $configPath) {
    try { return (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { $script:configReadError = $_.Exception.Message; return $null }
  }
  $script:configReadError = '파일이 없습니다'
  return $null
}

function Get-KeyEntry {
  param($Config, [int]$KeyCode)
  if (-not $Config) { return $null }
  $afterEntry = $Config.PSObject.Properties['afterEntry']
  if (-not $afterEntry) { return $null }
  $keys = $afterEntry.Value.PSObject.Properties['keys']
  if (-not $keys) { return $null }
  foreach ($entry in @($keys.Value)) {
    if ($entry.PSObject.Properties['key'] -and [int]$entry.key -eq $KeyCode) { return $entry }
  }
  return $null
}

function Save-Config {
  param($Config)
  $json = $Config | ConvertTo-Json -Depth 10
  # PS5.1 의 ConvertTo-Json 은 한글을 \uXXXX 로 바꾸므로 사람이 읽을 수 있게 복원합니다.
  $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
      param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
  Set-Content -LiteralPath $configPath -Value $json -Encoding UTF8
}

function Update-ConfigToLatest {
  # exe 업데이트 자동 이전: 사용자 config 의 좌표 버전(coordsVersion)이 내장 최신 config
  # (config.default.json - exe 가 매 실행마다 추출)보다 낮으면, 최신 config 를 기반으로
  # '사용자가 바꾸는 설정'만 옮겨 담아 config.json 을 재생성합니다.
  # 이렇게 하면 업데이트 때 좌표/구조는 항상 최신이 되고 사용자 설정은 유지됩니다.
  # 반환: 이전을 수행했으면 $true
  $defaultPath = Join-Path $scriptRoot 'config.default.json'
  if (-not (Test-Path -LiteralPath $defaultPath)) { return $false }
  try {
    $def = Get-Content -LiteralPath $defaultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $usr = Read-Config
    if (-not $usr -or -not $def) { return $false }
    $defVer = 0; if ($def.PSObject.Properties['coordsVersion']) { $defVer = [int]$def.coordsVersion }
    $usrVer = 0; if ($usr.PSObject.Properties['coordsVersion']) { $usrVer = [int]$usr.coordsVersion }
    if ($usrVer -ge $defVer) { return $false }

    # 1) 어비스 선택/카테고리 (프로파일 좌표는 최신 것 유지, 선택 값만 이전)
    if ($usr.PSObject.Properties['contentCategory']) { $def.contentCategory = $usr.contentCategory }
    if ($usr.PSObject.Properties['dungeons'] -and $def.PSObject.Properties['dungeons']) {
      foreach ($n in @('selected', 'mode', 'difficulty', 'matching')) {
        if ($usr.dungeons.PSObject.Properties[$n]) {
          if ($def.dungeons.PSObject.Properties[$n]) { $def.dungeons.$n = $usr.dungeons.$n }
          else { $def.dungeons | Add-Member -NotePropertyName $n -NotePropertyValue $usr.dungeons.$n }
        }
      }
    }
    # 2) 값 섹션들: '_' 주석 키를 제외하고, 최신 구조에 존재하는 키만 사용자 값으로 덮어씀
    #    (최신 구조에서 사라진 키는 버리고, 새로 생긴 키는 최신 기본값 유지)
    foreach ($sect in @('normalDungeon', 'huntingGround', 'timeoutsSeconds', 'focus', 'repeat', 'diagnostics', 'window', 'rdp')) {
      if ($usr.PSObject.Properties[$sect] -and $def.PSObject.Properties[$sect]) {
        foreach ($prop in $usr.$sect.PSObject.Properties) {
          if ($prop.Name -like '_*') { continue }
          if ($def.$sect.PSObject.Properties[$prop.Name]) { $def.$sect.($prop.Name) = $prop.Value }
        }
      }
    }
    # 3) 자동부활 on/off (키 코드/횟수 상한은 최신 기본값 유지)
    if ($usr.PSObject.Properties['revive'] -and $def.PSObject.Properties['revive'] -and
        $usr.revive.PSObject.Properties['enabled']) {
      $def.revive.enabled = [bool]$usr.revive.enabled
    }
    # 4) 입장 후 키 입력의 켬/끔 (키 코드로 짝을 맞춰 이전)
    if ($usr.PSObject.Properties['afterEntry'] -and $def.PSObject.Properties['afterEntry']) {
      foreach ($defKey in @($def.afterEntry.keys)) {
        $matchKey = @($usr.afterEntry.keys) | Where-Object { $_.PSObject.Properties['key'] -and [int]$_.key -eq [int]$defKey.key } | Select-Object -First 1
        if ($matchKey -and $matchKey.PSObject.Properties['enabled']) { $defKey.enabled = [bool]$matchKey.enabled }
      }
    }

    Save-Config $def
    return $true
  } catch { return $false }
}

# ----- 기존 자동화 프로세스 정리 -----
function Stop-ExistingAutomation {
  # 실제로 종료된 수와 실패한 수를 구분해 돌려줍니다. 실패를 성공처럼 보고하면
  # 새 워커가 '중복 실행'(코드 2)으로 죽는 원인을 사용자가 알 수 없게 됩니다.
  $pattern = 'mabinogi_controller\.ps1|mabinogi_run_once\.ps1'
  $killed = 0
  $failed = 0
  try {
    $existing = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
      Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $pattern })
    foreach ($proc in $existing) {
      try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; $killed++ } catch { $failed++ }
    }
    if ($existing.Count -gt 0) { Start-Sleep -Milliseconds 500 }
  } catch { }
  return @{ Killed = $killed; Failed = $failed }
}

# ----- RDP 자동 전환 예약 작업 -----
function Sync-RdpRedirectTask {
  param([bool]$Enable)
  try {
    $taskName = 'HoneyNogiRDPToConsole'
    # 옛 이름(MabinogiRDPToConsole)의 예약 작업이 남아 있으면 정리합니다 (꿀비노기 리네임 이전 버전)
    $legacyTask = Get-ScheduledTask -TaskName 'MabinogiRDPToConsole' -ErrorAction SilentlyContinue
    if ($legacyTask) {
      try { Unregister-ScheduledTask -TaskName 'MabinogiRDPToConsole' -Confirm:$false } catch { }
    }
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($Enable -and -not $existing -and (Test-Path -LiteralPath $redirectScript)) {
      $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $redirectScript + '"')
      $channel = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
      $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
      $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
      $trigger.Enabled = $true
      $trigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"$channel`"><Select Path=`"$channel`">*[System[(EventID=24)]]</Select></Query></QueryList>"
      $principalTask = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
      $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
      Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principalTask -Settings $settings -Force | Out-Null
      return 'installed'
    } elseif (-not $Enable -and $existing) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      return 'removed'
    }
    return 'unchanged'
  } catch { return "error: $($_.Exception.Message)" }
}

# ----- 로그 tail (다른 프로세스가 쓰는 중에도 안전하게 읽기) -----
function Read-LogLines {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  # 예외가 나도 파일 핸들이 남지 않도록 finally 에서 닫습니다.
  # (핸들이 남으면 다음 회차 시작 시 로그 파일 삭제가 실패할 수 있습니다)
  $fs = $null
  $sr = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    return @($text -split "`r?`n" | Where-Object { $_ })
  } catch { return $null }
  finally {
    if ($sr) { $sr.Close() }
    if ($fs) { $fs.Close() }
  }
}

# ----- 상태 변수 -----
$script:worker = $null
$script:running = $false
$script:stopRequested = $false
$script:completedCycles = 0
$script:targetCycles = 0      # 0 = 무한
$script:targetTime = $null    # 시간 지정 모드의 목표 시각 (null = 사용 안 함)
$script:logSeen = 0
$script:uiReady = $false      # 초기 로딩 중 설정 저장이 일어나지 않게 하는 플래그
$script:preparedStreak = 0    # 연속 '준비 실행'(코드 10) 횟수 - 화면 오판으로 인한 무한 준비 루프 방지 (컨트롤러와 동일)

# ============================================================
#  UI 구성
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "꿀비노기 컨트롤 패널 v$appVersion"
$form.Size = New-Object System.Drawing.Size(600, 872)
# 세로 크기 조절 가능: 로그 영역이 창 크기에 맞춰 늘어나고 줄어듭니다 (Anchor 설정 참고)
$form.FormBorderStyle = 'Sizable'
$form.MinimumSize = New-Object System.Drawing.Size(616, 700)
$form.MaximizeBox = $true
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
# 창/작업표시줄 아이콘: 스크립트 폴더에 app.ico 가 있으면 사용합니다 (exe가 실행 시 추출)
$appIconPath = Join-Path $scriptRoot 'app.ico'
if (Test-Path -LiteralPath $appIconPath) {
  try { $form.Icon = New-Object System.Drawing.Icon($appIconPath) } catch { }
}

# --- 상태 표시 ---
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(15, 12)
$lblStatus.Size = New-Object System.Drawing.Size(554, 26)
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblStatus.Text = '대기 중'
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStatus)

# --- 반복 설정 (가로 한 줄로 압축) ---
$grpRepeat = New-Object System.Windows.Forms.GroupBox
$grpRepeat.Text = '반복'
$grpRepeat.Location = New-Object System.Drawing.Point(15, 44)
$grpRepeat.Size = New-Object System.Drawing.Size(554, 52)
$form.Controls.Add($grpRepeat)

$rbInfinite = New-Object System.Windows.Forms.RadioButton
$rbInfinite.Text = '무한 반복'
$rbInfinite.Location = New-Object System.Drawing.Point(15, 20)
$rbInfinite.Size = New-Object System.Drawing.Size(85, 22)
$rbInfinite.Checked = $true
$grpRepeat.Controls.Add($rbInfinite)

$rbCount = New-Object System.Windows.Forms.RadioButton
$rbCount.Text = '횟수 지정:'
$rbCount.Location = New-Object System.Drawing.Point(125, 20)
$rbCount.Size = New-Object System.Drawing.Size(85, 22)
$grpRepeat.Controls.Add($rbCount)

$numCount = New-Object System.Windows.Forms.NumericUpDown
$numCount.Location = New-Object System.Drawing.Point(212, 18)
$numCount.Size = New-Object System.Drawing.Size(65, 24)
$numCount.Minimum = 1
$numCount.Maximum = 9999
$numCount.Value = 2
$grpRepeat.Controls.Add($numCount)

$rbTime = New-Object System.Windows.Forms.RadioButton
$rbTime.Text = '시간 지정:'
$rbTime.Location = New-Object System.Drawing.Point(310, 20)
$rbTime.Size = New-Object System.Drawing.Size(85, 22)
$grpRepeat.Controls.Add($rbTime)

$dtpUntil = New-Object System.Windows.Forms.DateTimePicker
$dtpUntil.Format = 'Custom'
$dtpUntil.CustomFormat = 'HH:mm'
$dtpUntil.ShowUpDown = $true
$dtpUntil.Location = New-Object System.Drawing.Point(397, 18)
$dtpUntil.Size = New-Object System.Drawing.Size(70, 24)
$grpRepeat.Controls.Add($dtpUntil)

# --- 제어 버튼 (한 줄) ---
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '시작(F9)'
$btnStart.Location = New-Object System.Drawing.Point(15, 104)
$btnStart.Size = New-Object System.Drawing.Size(150, 38)
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(70, 160, 90)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = 'Flat'
$form.Controls.Add($btnStart)

$btnSafeStop = New-Object System.Windows.Forms.Button
$btnSafeStop.Text = ("안전 중지(F9)" + [Environment]::NewLine + "(회차 완료 후)")
$btnSafeStop.Location = New-Object System.Drawing.Point(171, 104)
$btnSafeStop.Size = New-Object System.Drawing.Size(165, 38)
$btnSafeStop.Enabled = $false
$form.Controls.Add($btnSafeStop)

$btnKill = New-Object System.Windows.Forms.Button
$btnKill.Text = '즉시 중지(F10)'
$btnKill.Location = New-Object System.Drawing.Point(342, 104)
$btnKill.Size = New-Object System.Drawing.Size(105, 38)
$btnKill.Enabled = $false
$form.Controls.Add($btnKill)

# 선택한 콘텐츠에 맞는 사용 설명서 팝업 (어비스 설명서 / 던전 설명서 - 카테고리에 따라 자동 전환)
$btnManual = New-Object System.Windows.Forms.Button
$btnManual.Text = '어비스 설명서'
$btnManual.Location = New-Object System.Drawing.Point(453, 104)
$btnManual.Size = New-Object System.Drawing.Size(116, 38)
$form.Controls.Add($btnManual)

$btnManual.Add_Click({
    # 모든 설명서 공통 머리말 (콘텐츠와 무관하게 동일)
    $manualCommon = "이 매크로는 게임 화면을 캡처해 글자를 읽는(OCR) 방식으로 동작합니다.`n" +
    "화면 비율/크기가 기준과 다르면 OCR 인식이 어긋나 오류가 발생할 수 있으니,`n" +
    "게임을 16:9 비율의 창 모드로 실행해 주세요.`n`n" +
    "[매크로 필수]`n" +
    " - OCR 언어 필요: 한국어(ko), 영어(en-US)`n" +
    " - OCR이 없으면 최초 [시작] 시 자동 설치합니다`n" +
    "   (영어는 백그라운드 설치, 10~15분 소요될 수 있음)`n" +
    " - 단축키: F9 = 시작 / 안전 중지, F10 = 즉시 중지`n" +
    "   (게임 화면에서도 동작합니다)`n`n"
    if ($rbCatHunting.Checked) {
      $manualText = $manualCommon +
      "[사냥터 자동화 사용법]`n" +
      " 1) 게임을 창 모드로 변경합니다.`n" +
      " 2) 원하는 사냥터의 석상을 클릭하여 사냥터 구역 선택 화면을 열어둡니다.`n" +
      " 3) [시작] 버튼을 클릭 후 마우스를 잠시 움직이지 마세요."
      [System.Windows.Forms.MessageBox]::Show($manualText, '사냥터 설명서',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
      return
    }
    if ($rbCatDungeon.Checked) {
      $manualText = $manualCommon +
      "[던전 자동화 사용법]`n" +
      " 1) 게임을 창 모드로 변경합니다.`n" +
      " 2) 원하는 던전의 석상을 클릭하여 던전 구역 선택 화면을 열어둡니다.`n" +
      " 3) [시작] 버튼을 클릭 후 마우스를 잠시 움직이지 마세요."
      [System.Windows.Forms.MessageBox]::Show($manualText, '던전 설명서',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } else {
      $manualText = $manualCommon +
      "[어비스 사용법]`n" +
      " 1) 게임을 창 모드로 변경합니다.`n" +
      " 2) [시작] 버튼을 클릭해주세요.`n" +
      "    - 어비스 던전 선택 화면에서 [시작] 시 가장 안정적`n" +
      " 3) 마우스를 잠시 움직이지 마세요.`n`n" +
      "※ 매칭 '파티(파티장)': 파티를 먼저 짠 상태에서 시작하세요.`n" +
      "   입장하기 후 파티원 전원이 준비되면 자동 입장됩니다.`n" +
      "   (인원이 부족해도 채우지 않고 확인 팝업을 넘겨 그대로 도전합니다)`n" +
      "※ 매칭 '파티(파티원)': 파티를 짠 상태로 캐릭터를 필드에 두고 시작하세요.`n" +
      "   파티장이 입장을 시작하면 자동으로 '준비 완료'를 누르고 따라갑니다.`n" +
      "   (메뉴 이동 없이 대기 → 입장 → 클리어 → 나가기만 반복)"
      [System.Windows.Forms.MessageBox]::Show($manualText, '어비스 설명서',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
  })

# --- 콘텐츠 선택 (종류: 어비스/던전/심층던전) ---
$grpContent = New-Object System.Windows.Forms.GroupBox
$grpContent.Text = '콘텐츠 선택'
$grpContent.Location = New-Object System.Drawing.Point(15, 150)
$grpContent.Size = New-Object System.Drawing.Size(554, 52)
$form.Controls.Add($grpContent)

# --- 콘텐츠 상세 설정 (입장 방식 / 난이도 / 세부 던전) ---
$grpContentDetail = New-Object System.Windows.Forms.GroupBox
$grpContentDetail.Text = '콘텐츠 상세 설정'
$grpContentDetail.Location = New-Object System.Drawing.Point(15, 210)
$grpContentDetail.Size = New-Object System.Drawing.Size(554, 122)
$form.Controls.Add($grpContentDetail)

# 1줄: 콘텐츠 종류 (라디오 그룹 분리를 위해 Panel 로 감쌈)
$pnlCategory = New-Object System.Windows.Forms.Panel
$pnlCategory.Location = New-Object System.Drawing.Point(15, 20)
$pnlCategory.Size = New-Object System.Drawing.Size(524, 26)
$grpContent.Controls.Add($pnlCategory)

$rbCatAbyss = New-Object System.Windows.Forms.RadioButton
$rbCatAbyss.Text = '어비스'
$rbCatAbyss.Location = New-Object System.Drawing.Point(0, 2)
$rbCatAbyss.Size = New-Object System.Drawing.Size(80, 22)
$rbCatAbyss.Checked = $true
$pnlCategory.Controls.Add($rbCatAbyss)

$rbCatDungeon = New-Object System.Windows.Forms.RadioButton
$rbCatDungeon.Text = '던전'
$rbCatDungeon.Location = New-Object System.Drawing.Point(100, 2)
$rbCatDungeon.Size = New-Object System.Drawing.Size(70, 22)
$pnlCategory.Controls.Add($rbCatDungeon)

$rbCatHunting = New-Object System.Windows.Forms.RadioButton
$rbCatHunting.Text = '사냥터'
$rbCatHunting.Location = New-Object System.Drawing.Point(180, 2)
$rbCatHunting.Size = New-Object System.Drawing.Size(130, 22)
$pnlCategory.Controls.Add($rbCatHunting)

$rbCatDeep = New-Object System.Windows.Forms.RadioButton
$rbCatDeep.Text = '심층던전 (개발 예정)'
$rbCatDeep.Location = New-Object System.Drawing.Point(320, 2)
$rbCatDeep.Size = New-Object System.Drawing.Size(160, 22)
$rbCatDeep.Enabled = $false
$pnlCategory.Controls.Add($rbCatDeep)

# 상세 설정 1줄: 입장 방식 (혼자하기 / 함께하기)
$pnlMode = New-Object System.Windows.Forms.Panel
$pnlMode.Location = New-Object System.Drawing.Point(15, 20)
$pnlMode.Size = New-Object System.Drawing.Size(524, 26)
$grpContentDetail.Controls.Add($pnlMode)

$rbModeSolo = New-Object System.Windows.Forms.RadioButton
$rbModeSolo.Text = '혼자하기'
$rbModeSolo.Location = New-Object System.Drawing.Point(0, 2)
$rbModeSolo.Size = New-Object System.Drawing.Size(90, 22)
$rbModeSolo.Checked = $true
$pnlMode.Controls.Add($rbModeSolo)

$rbModeParty = New-Object System.Windows.Forms.RadioButton
$rbModeParty.Text = '함께하기'
$rbModeParty.Location = New-Object System.Drawing.Point(140, 2)
$rbModeParty.Size = New-Object System.Drawing.Size(200, 22)
$pnlMode.Controls.Add($rbModeParty)

# 상세 설정 2줄: 난이도 선택 (드롭다운). 워커가 상세 화면에서 같은 이름의 난이도 버튼을
#      OCR로 찾아 클릭합니다. '게임 그대로'는 난이도를 건드리지 않고 현재 선택된 상태로 입장.
#      새 난이도가 추가되면 아래 목록에 이름만 추가하면 됩니다 (워커는 글자 탐색이라 수정 불필요).
$pnlDifficulty = New-Object System.Windows.Forms.Panel
$pnlDifficulty.Location = New-Object System.Drawing.Point(15, 52)
$pnlDifficulty.Size = New-Object System.Drawing.Size(524, 26)
$grpContentDetail.Controls.Add($pnlDifficulty)

$lblDifficulty = New-Object System.Windows.Forms.Label
$lblDifficulty.Text = '난이도:'
$lblDifficulty.Location = New-Object System.Drawing.Point(0, 5)
$lblDifficulty.Size = New-Object System.Drawing.Size(52, 20)
$pnlDifficulty.Controls.Add($lblDifficulty)

$cboDifficulty = New-Object System.Windows.Forms.ComboBox
$cboDifficulty.Location = New-Object System.Drawing.Point(58, 1)
$cboDifficulty.Size = New-Object System.Drawing.Size(150, 24)
$cboDifficulty.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
# 난이도 목록은 입장 방식에 따라 달라집니다: 지옥 난이도는 함께하기(파티) 전용이라
# 혼자하기에서는 '매우 어려움'까지만 선택할 수 있습니다. 방식 전환 시 목록을 갈아끼우고,
# 선택 중이던 난이도가 새 목록에 없으면 '게임 그대로'로 되돌립니다.
$updateDifficultyItems = {
  $currentDifficulty = [string]$cboDifficulty.SelectedItem
  $cboDifficulty.Items.Clear()
  [void]$cboDifficulty.Items.Add('게임 그대로')
  foreach ($difficultyName in @('입문', '어려움', '매우 어려움')) { [void]$cboDifficulty.Items.Add($difficultyName) }
  if ($rbModeParty.Checked) {
    for ($hellLevel = 1; $hellLevel -le 10; $hellLevel++) { [void]$cboDifficulty.Items.Add("지옥$hellLevel") }
  }
  if ($currentDifficulty -and $cboDifficulty.Items.Contains($currentDifficulty)) {
    $cboDifficulty.SelectedItem = $currentDifficulty
  } else {
    $cboDifficulty.SelectedIndex = 0
  }
}
& $updateDifficultyItems
$pnlDifficulty.Controls.Add($cboDifficulty)

$rbModeSolo.Add_CheckedChanged({
    & $updateDifficultyItems
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })
$rbModeParty.Add_CheckedChanged({
    & $updateDifficultyItems
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })

# 3줄: 세부 던전 목록 (1줄에서 고른 종류에 따라 내용이 바뀌는 자리.
#      지금은 어비스만 있으므로 어비스 던전 3종을 표시. 추후 던전/심층던전이
#      개발되면 카테고리 CheckedChanged 에서 이 패널의 항목을 갈아끼우면 됨)
$pnlDungeon = New-Object System.Windows.Forms.Panel
$pnlDungeon.Location = New-Object System.Drawing.Point(15, 84)
$pnlDungeon.Size = New-Object System.Drawing.Size(524, 26)
$grpContentDetail.Controls.Add($pnlDungeon)

$rbDgHeosang = New-Object System.Windows.Forms.RadioButton
$rbDgHeosang.Text = '허상의 정박지'
$rbDgHeosang.Location = New-Object System.Drawing.Point(0, 2)
$rbDgHeosang.Size = New-Object System.Drawing.Size(120, 22)
$rbDgHeosang.Checked = $true
$pnlDungeon.Controls.Add($rbDgHeosang)

$rbDgMadness = New-Object System.Windows.Forms.RadioButton
$rbDgMadness.Text = '광기의 동굴'
$rbDgMadness.Location = New-Object System.Drawing.Point(140, 2)
$rbDgMadness.Size = New-Object System.Drawing.Size(185, 22)
$pnlDungeon.Controls.Add($rbDgMadness)

$rbDgScattered = New-Object System.Windows.Forms.RadioButton
$rbDgScattered.Text = '흩어진 물길'
$rbDgScattered.Location = New-Object System.Drawing.Point(340, 2)
$rbDgScattered.Size = New-Object System.Drawing.Size(185, 22)
$pnlDungeon.Controls.Add($rbDgScattered)

# 함께하기 전용 매칭 방식 줄 (우연한 만남 / 파티 찾기). 함께하기를 선택하면 난이도
# 아래에 나타나고, 세부 던전 목록이 한 줄 아래로 내려갑니다 (배치는 updateCategoryPanels).
$pnlAbyssMatching = New-Object System.Windows.Forms.Panel
$pnlAbyssMatching.Location = New-Object System.Drawing.Point(15, 84)
$pnlAbyssMatching.Size = New-Object System.Drawing.Size(524, 26)
$pnlAbyssMatching.Visible = $false
$grpContentDetail.Controls.Add($pnlAbyssMatching)

$lblAbyssMatching = New-Object System.Windows.Forms.Label
$lblAbyssMatching.Text = '매칭:'
$lblAbyssMatching.Location = New-Object System.Drawing.Point(0, 5)
$lblAbyssMatching.Size = New-Object System.Drawing.Size(52, 20)
$pnlAbyssMatching.Controls.Add($lblAbyssMatching)

$rbAbyssChance = New-Object System.Windows.Forms.RadioButton
$rbAbyssChance.Text = '우연한 만남'
$rbAbyssChance.Location = New-Object System.Drawing.Point(58, 2)
$rbAbyssChance.Size = New-Object System.Drawing.Size(110, 22)
$rbAbyssChance.Checked = $true
$pnlAbyssMatching.Controls.Add($rbAbyssChance)

$rbAbyssFindParty = New-Object System.Windows.Forms.RadioButton
$rbAbyssFindParty.Text = '파티 찾기'
$rbAbyssFindParty.Location = New-Object System.Drawing.Point(190, 2)
$rbAbyssFindParty.Size = New-Object System.Drawing.Size(100, 22)
$pnlAbyssMatching.Controls.Add($rbAbyssFindParty)

# 직접 짠 파티로 도는 모드 (파티장 = 입장하기 클릭 주도 / 파티원 = 준비·따라가기 전담)
$rbAbyssPartyLead = New-Object System.Windows.Forms.RadioButton
$rbAbyssPartyLead.Text = '파티(파티장)'
$rbAbyssPartyLead.Location = New-Object System.Drawing.Point(296, 2)
$rbAbyssPartyLead.Size = New-Object System.Drawing.Size(110, 22)
$pnlAbyssMatching.Controls.Add($rbAbyssPartyLead)

$rbAbyssPartyMember = New-Object System.Windows.Forms.RadioButton
$rbAbyssPartyMember.Text = '파티(파티원)'
$rbAbyssPartyMember.Location = New-Object System.Drawing.Point(410, 2)
$rbAbyssPartyMember.Size = New-Object System.Drawing.Size(110, 22)
$pnlAbyssMatching.Controls.Add($rbAbyssPartyMember)

# ============================================================
#  '던전' 카테고리 전용 상세 설정 (콘텐츠 선택에서 '던전'을 고르면 아래 패널들이 표시되고
#  어비스용 패널은 숨겨집니다. 전체 자동화 구현: 선택 → 옵션 → 입장 → 클리어 → 다시 하기 반복)
# ============================================================
# 1줄: 난이도 (일반 / 어려움)
$pnlNdDifficulty = New-Object System.Windows.Forms.Panel
$pnlNdDifficulty.Location = New-Object System.Drawing.Point(15, 20)
$pnlNdDifficulty.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdDifficulty.Visible = $false
$grpContentDetail.Controls.Add($pnlNdDifficulty)

$lblNdDifficulty = New-Object System.Windows.Forms.Label
$lblNdDifficulty.Text = '난이도:'
$lblNdDifficulty.Location = New-Object System.Drawing.Point(0, 5)
$lblNdDifficulty.Size = New-Object System.Drawing.Size(52, 20)
$pnlNdDifficulty.Controls.Add($lblNdDifficulty)

$rbNdNormal = New-Object System.Windows.Forms.RadioButton
$rbNdNormal.Text = '일반'
$rbNdNormal.Location = New-Object System.Drawing.Point(58, 2)
$rbNdNormal.Size = New-Object System.Drawing.Size(60, 22)
$rbNdNormal.Checked = $true
$pnlNdDifficulty.Controls.Add($rbNdNormal)

$rbNdHard = New-Object System.Windows.Forms.RadioButton
$rbNdHard.Text = '어려움'
$rbNdHard.Location = New-Object System.Drawing.Point(128, 2)
$rbNdHard.Size = New-Object System.Drawing.Size(75, 22)
$pnlNdDifficulty.Controls.Add($rbNdHard)

# 2줄: 스테이지 (1-1 ~ 2-3 드롭다운. 새 스테이지가 나오면 목록에 추가)
$pnlNdStage = New-Object System.Windows.Forms.Panel
$pnlNdStage.Location = New-Object System.Drawing.Point(15, 52)
$pnlNdStage.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdStage.Visible = $false
$grpContentDetail.Controls.Add($pnlNdStage)

$lblNdStage = New-Object System.Windows.Forms.Label
$lblNdStage.Text = '스테이지:'
$lblNdStage.Location = New-Object System.Drawing.Point(0, 5)
$lblNdStage.Size = New-Object System.Drawing.Size(62, 20)
$pnlNdStage.Controls.Add($lblNdStage)

$cboNdStage = New-Object System.Windows.Forms.ComboBox
$cboNdStage.Location = New-Object System.Drawing.Point(68, 1)
$cboNdStage.Size = New-Object System.Drawing.Size(100, 24)
$cboNdStage.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($ndChapter in 1..2) {
  foreach ($ndStep in 1..3) { [void]$cboNdStage.Items.Add("$ndChapter-$ndStep") }
}
$cboNdStage.SelectedIndex = 0
$pnlNdStage.Controls.Add($cboNdStage)

# 3줄: 은동전 사용 (체크하면 바로 옆에 더블 루팅 선택이 나타남)
$pnlNdCoin = New-Object System.Windows.Forms.Panel
$pnlNdCoin.Location = New-Object System.Drawing.Point(15, 84)
$pnlNdCoin.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdCoin.Visible = $false
$grpContentDetail.Controls.Add($pnlNdCoin)

$chkNdCoin = New-Object System.Windows.Forms.CheckBox
$chkNdCoin.Text = '은동전 사용'
$chkNdCoin.Location = New-Object System.Drawing.Point(0, 2)
$chkNdCoin.Size = New-Object System.Drawing.Size(105, 22)
$pnlNdCoin.Controls.Add($chkNdCoin)

$chkNdDoubleLoot = New-Object System.Windows.Forms.CheckBox
$chkNdDoubleLoot.Text = '더블 루팅'
$chkNdDoubleLoot.Location = New-Object System.Drawing.Point(125, 2)
$chkNdDoubleLoot.Size = New-Object System.Drawing.Size(95, 22)
$chkNdDoubleLoot.Visible = $false
$pnlNdCoin.Controls.Add($chkNdDoubleLoot)

# 소진 대응 줄 (은동전 사용을 체크했을 때만 표시):
#  - 소진 시 미사용으로 계속: 잔량 10개 미만이면 소탕을 해제하고 미사용(도전)으로 반복
#  - 더블 루팅 불가 시 소탕만 계속: 잔량 10~19개면 더블 루팅만 끄고 소탕(10개)으로 반복
$pnlNdFallback = New-Object System.Windows.Forms.Panel
$pnlNdFallback.Location = New-Object System.Drawing.Point(15, 116)
$pnlNdFallback.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdFallback.Visible = $false
$grpContentDetail.Controls.Add($pnlNdFallback)

$chkNdCoinFallback = New-Object System.Windows.Forms.CheckBox
$chkNdCoinFallback.Text = '소진 시 미사용으로 계속'
$chkNdCoinFallback.Location = New-Object System.Drawing.Point(20, 2)
$chkNdCoinFallback.Size = New-Object System.Drawing.Size(200, 22)
$pnlNdFallback.Controls.Add($chkNdCoinFallback)

$chkNdLootFallback = New-Object System.Windows.Forms.CheckBox
$chkNdLootFallback.Text = '더블 루팅 불가 시 소탕만 계속'
$chkNdLootFallback.Location = New-Object System.Drawing.Point(240, 2)
$chkNdLootFallback.Size = New-Object System.Drawing.Size(240, 22)
$chkNdLootFallback.Enabled = $false   # 더블 루팅을 켰을 때만 의미 있는 옵션이라 그때만 활성화
$pnlNdFallback.Controls.Add($chkNdLootFallback)

# 더블 루팅을 체크했을 때만 '소탕만 계속' 옵션을 켤 수 있고, 해제하면 선택도 함께 풉니다
$chkNdDoubleLoot.Add_CheckedChanged({
    $chkNdLootFallback.Enabled = $chkNdDoubleLoot.Checked
    if (-not $chkNdDoubleLoot.Checked) { $chkNdLootFallback.Checked = $false }
  })

# 은동전 사용을 체크하면 더블 루팅과 소진 대응 줄이 나타나고, 해제하면 숨기면서 선택도 해제합니다
$chkNdCoin.Add_CheckedChanged({
    $chkNdDoubleLoot.Visible = $chkNdCoin.Checked
    if (-not $chkNdCoin.Checked) {
      $chkNdDoubleLoot.Checked = $false
      $chkNdCoinFallback.Checked = $false
      $chkNdLootFallback.Checked = $false
    }
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })

# ============================================================
#  '사냥터' 카테고리 전용 상세 설정 (특정 사냥터에 매이지 않는 범용 방식 -
#  사용자가 원하는 사냥터의 첫 화면을 열어 두면 그 사냥터로 동작합니다)
# ============================================================
# 1줄: 난이도 (일반 / 어려움)
$pnlHtDifficulty = New-Object System.Windows.Forms.Panel
$pnlHtDifficulty.Location = New-Object System.Drawing.Point(15, 20)
$pnlHtDifficulty.Size = New-Object System.Drawing.Size(524, 26)
$pnlHtDifficulty.Visible = $false
$grpContentDetail.Controls.Add($pnlHtDifficulty)

$lblHtDifficulty = New-Object System.Windows.Forms.Label
$lblHtDifficulty.Text = '난이도:'
$lblHtDifficulty.Location = New-Object System.Drawing.Point(0, 5)
$lblHtDifficulty.Size = New-Object System.Drawing.Size(52, 20)
$pnlHtDifficulty.Controls.Add($lblHtDifficulty)

$rbHtNormal = New-Object System.Windows.Forms.RadioButton
$rbHtNormal.Text = '일반'
$rbHtNormal.Location = New-Object System.Drawing.Point(58, 2)
$rbHtNormal.Size = New-Object System.Drawing.Size(60, 22)
$rbHtNormal.Checked = $true
$pnlHtDifficulty.Controls.Add($rbHtNormal)

$rbHtHard = New-Object System.Windows.Forms.RadioButton
$rbHtHard.Text = '어려움'
$rbHtHard.Location = New-Object System.Drawing.Point(128, 2)
$rbHtHard.Size = New-Object System.Drawing.Size(75, 22)
$pnlHtDifficulty.Controls.Add($rbHtHard)

# 매우 어려움은 일부 사냥터에만 있습니다. 없는 사냥터에서 선택하면
# 해당 글자를 찾지 못해 현재 선택된 난이도로 진행합니다(중단 없음).
$rbHtVeryHard = New-Object System.Windows.Forms.RadioButton
$rbHtVeryHard.Text = '매우 어려움'
$rbHtVeryHard.Location = New-Object System.Drawing.Point(213, 2)
$rbHtVeryHard.Size = New-Object System.Drawing.Size(105, 22)
$pnlHtDifficulty.Controls.Add($rbHtVeryHard)

# 2줄: 공물(은동전 10개) 사용 + 소진 대응
$pnlHtCoin = New-Object System.Windows.Forms.Panel
$pnlHtCoin.Location = New-Object System.Drawing.Point(15, 52)
$pnlHtCoin.Size = New-Object System.Drawing.Size(524, 26)
$pnlHtCoin.Visible = $false
$grpContentDetail.Controls.Add($pnlHtCoin)

$chkHtCoin = New-Object System.Windows.Forms.CheckBox
$chkHtCoin.Text = '은동전 사용'
$chkHtCoin.Location = New-Object System.Drawing.Point(0, 2)
$chkHtCoin.Size = New-Object System.Drawing.Size(105, 22)
$pnlHtCoin.Controls.Add($chkHtCoin)

$chkHtDoubleLoot = New-Object System.Windows.Forms.CheckBox
$chkHtDoubleLoot.Text = '더블 루팅'
$chkHtDoubleLoot.Location = New-Object System.Drawing.Point(125, 2)
$chkHtDoubleLoot.Size = New-Object System.Drawing.Size(95, 22)
$chkHtDoubleLoot.Visible = $false
$pnlHtCoin.Controls.Add($chkHtDoubleLoot)

# 사냥터 소진 대응 (사용자 결정 2026-07-18): '소진 시 미사용으로 계속'은 없습니다 -
# 은동전이 10개 미만이면 사냥터에서 나가서 자동화를 마칩니다. 단 '더블 루팅 불가 시
# 소탕만 계속'은 유지: 잔량 10~19개면 더블 루팅만 끄고 소탕(10개)으로 계속합니다.
$chkHtLootFallback = New-Object System.Windows.Forms.CheckBox
$chkHtLootFallback.Text = '더블 루팅 불가 시 소탕만 계속'
$chkHtLootFallback.Location = New-Object System.Drawing.Point(240, 2)
$chkHtLootFallback.Size = New-Object System.Drawing.Size(240, 22)
$chkHtLootFallback.Visible = $false
$chkHtLootFallback.Enabled = $false   # 더블 루팅을 켰을 때만 의미 있는 옵션이라 그때만 활성화
$pnlHtCoin.Controls.Add($chkHtLootFallback)

$chkHtDoubleLoot.Add_CheckedChanged({
    $chkHtLootFallback.Enabled = $chkHtDoubleLoot.Checked
    if (-not $chkHtDoubleLoot.Checked) { $chkHtLootFallback.Checked = $false }
  })

# 은동전 사용을 체크하면 더블 루팅/소탕만 계속이 나타나고, 해제하면 숨기면서 선택도 해제합니다
$chkHtCoin.Add_CheckedChanged({
    $chkHtDoubleLoot.Visible = $chkHtCoin.Checked
    $chkHtLootFallback.Visible = $chkHtCoin.Checked
    if (-not $chkHtCoin.Checked) {
      $chkHtDoubleLoot.Checked = $false
      $chkHtLootFallback.Checked = $false
    }
  })

# 3줄: 매칭 방식 (파티찾기 / 바로 입장)
$pnlHtParty = New-Object System.Windows.Forms.Panel
$pnlHtParty.Location = New-Object System.Drawing.Point(15, 84)
$pnlHtParty.Size = New-Object System.Drawing.Size(524, 26)
$pnlHtParty.Visible = $false
$grpContentDetail.Controls.Add($pnlHtParty)

$rbHtParty = New-Object System.Windows.Forms.RadioButton
$rbHtParty.Text = '파티찾기'
$rbHtParty.Location = New-Object System.Drawing.Point(0, 2)
$rbHtParty.Size = New-Object System.Drawing.Size(90, 22)
$rbHtParty.Checked = $true
$pnlHtParty.Controls.Add($rbHtParty)

$rbHtDirect = New-Object System.Windows.Forms.RadioButton
$rbHtDirect.Text = '바로 입장'
$rbHtDirect.Location = New-Object System.Drawing.Point(105, 2)
$rbHtDirect.Size = New-Object System.Drawing.Size(95, 22)
$pnlHtParty.Controls.Add($rbHtDirect)

# 4줄: 매칭 방식 (파티찾기 / 우연한 만남)
$pnlNdParty = New-Object System.Windows.Forms.Panel
$pnlNdParty.Location = New-Object System.Drawing.Point(15, 116)
$pnlNdParty.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdParty.Visible = $false
$grpContentDetail.Controls.Add($pnlNdParty)

$rbNdChance = New-Object System.Windows.Forms.RadioButton
$rbNdChance.Text = '우연한 만남'
$rbNdChance.Location = New-Object System.Drawing.Point(0, 2)
$rbNdChance.Size = New-Object System.Drawing.Size(110, 22)
$rbNdChance.Checked = $true
$pnlNdParty.Controls.Add($rbNdChance)

$rbNdFindParty = New-Object System.Windows.Forms.RadioButton
$rbNdFindParty.Text = '파티찾기'
$rbNdFindParty.Location = New-Object System.Drawing.Point(125, 2)
$rbNdFindParty.Size = New-Object System.Drawing.Size(90, 22)
$pnlNdParty.Controls.Add($rbNdFindParty)

# --- 설정 (on/off) ---
$grpSettings = New-Object System.Windows.Forms.GroupBox
$grpSettings.Text = '설정'
$grpSettings.Location = New-Object System.Drawing.Point(15, 340)
$grpSettings.Size = New-Object System.Drawing.Size(554, 150)
$form.Controls.Add($grpSettings)

$chkSpace = New-Object System.Windows.Forms.CheckBox
$chkSpace.Text = '자동출발 (Space)'
$chkSpace.Location = New-Object System.Drawing.Point(15, 25)
$chkSpace.Size = New-Object System.Drawing.Size(150, 22)
$grpSettings.Controls.Add($chkSpace)

$chkFood = New-Object System.Windows.Forms.CheckBox
$chkFood.Text = '음식 자동 먹기 (B)'
$chkFood.Location = New-Object System.Drawing.Point(15, 52)
$chkFood.Size = New-Object System.Drawing.Size(150, 22)
$grpSettings.Controls.Add($chkFood)

$chkRevive = New-Object System.Windows.Forms.CheckBox
$chkRevive.Text = '자동부활 (불사의 가루)'
$chkRevive.Location = New-Object System.Drawing.Point(15, 79)
$chkRevive.Size = New-Object System.Drawing.Size(185, 22)
$grpSettings.Controls.Add($chkRevive)

# 권장 창 모드 버튼: 클릭하면 게임 창을 OCR 인식 최적 크기(QHD 이상=1908x1076,
# FHD 등=1272x717, 작업표시줄 안 겹치게)로 즉시 변경합니다. 한 번 맞춰두면
# 매 회차 자동 보정이 그 크기를 그대로 유지하므로 별도 상시 설정이 필요 없습니다.
$btnRecommendedWindow = New-Object System.Windows.Forms.Button
$btnRecommendedWindow.Text = '권장 창 모드'
$btnRecommendedWindow.Location = New-Object System.Drawing.Point(400, 25)
$btnRecommendedWindow.Size = New-Object System.Drawing.Size(138, 30)
$grpSettings.Controls.Add($btnRecommendedWindow)

# '적용된 설정' 버튼: 설정 그룹에서 켜 둔 항목과 기본 설정 기능(항상 자동 동작)을
# 한 팝업으로 보여줍니다 (설정 저장 버튼 위). 콘텐츠/난이도 등은 화면에서 바로
# 보이므로 팝업에는 넣지 않습니다. 켠 항목만 누를 때 상태를 읽어 표시합니다.
$btnAlwaysOn = New-Object System.Windows.Forms.Button
$btnAlwaysOn.Text = '적용된 설정'
$btnAlwaysOn.Location = New-Object System.Drawing.Point(400, 70)
$btnAlwaysOn.Size = New-Object System.Drawing.Size(138, 30)
$grpSettings.Controls.Add($btnAlwaysOn)

$btnAlwaysOn.Add_Click({
    # 체크박스 항목은 켠 것만 표시합니다 (꺼진 항목은 줄 자체를 생략)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[내가 선택한 설정] (켠 항목만 표시)')
    $lines.Add(" - 클리어 대기: $([int]$numClearWait.Value)초")
    if ($chkSpace.Checked) { $lines.Add(" - $($chkSpace.Text)") }
    if ($chkFood.Checked) { $lines.Add(" - $($chkFood.Text)") }
    if ($chkRevive.Checked) { $lines.Add(" - $($chkRevive.Text)") }
    $lines.Add('')
    $lines.Add('[기본 설정 기능]')
    $lines.Add('<화면/창 관리>')
    $lines.Add(' - 게임 창 자동 정렬 (크기·위치 보정)')
    $lines.Add(' - 게임 창이 가려지면 자동 복구')
    $lines.Add(' - 화면 캡처 실패 시 일시정지 후 자동 복구 (최소화/끊김/재접속 구분 안내)')
    $lines.Add('')
    $lines.Add('<진행 자동 처리>')
    $lines.Add(' - 출석 자동 넘기기(우편보상지급)')
    $lines.Add(' - 오늘의 스텔라 픽 자동 확정')
    $lines.Add(' - 공지/이벤트 팝업 자동 닫기')
    $lines.Add(' - 보스방/엔딩 컷신 자동 스킵')
    $lines.Add(' - 구매 안내 팝업(물약 부족 등) 자동 닫기')
    $lines.Add(' - 자동사냥 꺼짐 감시 (꺼져 있으면 자동출발)')
    $lines.Add(' - 클릭이 빗나가면 확인 후 자동 재클릭')
    $lines.Add(" - 던전 입장 확인 팝업 '일주일 동안 보지 않기' 자동 체크")
    $lines.Add(' - 은동전 소탕 전리품 공개 화면 자동 진행')
    $lines.Add(' - 부활 재료(불사의 가루) 부족 시 여신상 부활로 자동 전환')
    $appliedText = ($lines -join "`n")
    [System.Windows.Forms.MessageBox]::Show($appliedText, '적용된 설정',
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
  })

# '?' 도움말 버튼: 파란 원형 배지, 클릭하면 클리어 대기 시간 설명 팝업
$btnClearHelp = New-Object System.Windows.Forms.Button
$btnClearHelp.Text = '?'
$btnClearHelp.Location = New-Object System.Drawing.Point(16, 110)
$btnClearHelp.Size = New-Object System.Drawing.Size(18, 18)
$btnClearHelp.FlatStyle = 'Flat'
$btnClearHelp.FlatAppearance.BorderSize = 0
$btnClearHelp.BackColor = [System.Drawing.Color]::SteelBlue
$btnClearHelp.ForeColor = [System.Drawing.Color]::White
$btnClearHelp.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$btnClearHelp.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnClearHelp.TextAlign = 'MiddleCenter'
# 버튼을 원형으로 잘라냅니다
$helpCirclePath = New-Object System.Drawing.Drawing2D.GraphicsPath
$helpCirclePath.AddEllipse(0, 0, $btnClearHelp.Width, $btnClearHelp.Height)
$btnClearHelp.Region = New-Object System.Drawing.Region($helpCirclePath)
$grpSettings.Controls.Add($btnClearHelp)

$btnClearHelp.Add_Click({
    $helpText = "던전에 입장한 뒤 '던전 클리어!' 화면이 뜰 때까지 기다리는 최대 시간입니다.`n`n" +
    "- 클리어가 감지되면 즉시 다음 단계로 넘어갑니다 (설정한 시간을 다 기다리지 않음)`n" +
    "- 이 시간을 넘겨도 클리어 화면이 안 나오면 문제가 생긴 것으로 판단하고 그 회차를 중단합니다`n`n" +
    "즉, '한 판이 아무리 길어도 이 시간 안에는 끝난다'는 안전 한도입니다.`n" +
    "보통 한 판에 3~4분 걸리므로 기본값 600초(10분)면 충분하고,`n" +
    "더 오래 걸리는 던전이라면 여유 있게 늘려 주세요."
    [System.Windows.Forms.MessageBox]::Show($helpText, '클리어 대기 시간이란?',
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
  })

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($btnClearHelp, '클릭하면 자세한 설명이 나옵니다')
$toolTip.SetToolTip($chkRevive, "전투 중 행동불능이 되면 남은 부활 횟수를 확인해 R키(여기서 부활)로 자동 부활합니다.`r`n남은 횟수가 없으면 '여신상에서 부활'을 클릭해 이어갑니다.`r`n불사의 가루 등 부활 재화가 소모될 수 있으니 원치 않으면 꺼 두세요.")

$lblClearWait = New-Object System.Windows.Forms.Label
$lblClearWait.Text = '클리어 대기(초):'
$lblClearWait.Location = New-Object System.Drawing.Point(40, 111)
$lblClearWait.Size = New-Object System.Drawing.Size(95, 20)
$grpSettings.Controls.Add($lblClearWait)

$numClearWait = New-Object System.Windows.Forms.NumericUpDown
$numClearWait.Location = New-Object System.Drawing.Point(137, 108)
$numClearWait.Size = New-Object System.Drawing.Size(65, 24)
$numClearWait.Minimum = 60
$numClearWait.Maximum = 10800
$numClearWait.Value = 600
$grpSettings.Controls.Add($numClearWait)

# 초 → 분·초 환산 표시 (값이 바뀔 때마다 자동 갱신)
$lblClearHuman = New-Object System.Windows.Forms.Label
$lblClearHuman.Location = New-Object System.Drawing.Point(210, 111)
$lblClearHuman.Size = New-Object System.Drawing.Size(160, 20)
$lblClearHuman.ForeColor = [System.Drawing.Color]::SteelBlue
$grpSettings.Controls.Add($lblClearHuman)

$updateClearHuman = {
  $totalSeconds = [int]$numClearWait.Value
  $hours = [Math]::Floor($totalSeconds / 3600)
  $minutes = [Math]::Floor(($totalSeconds % 3600) / 60)
  $seconds = $totalSeconds % 60
  $parts = @()
  if ($hours -gt 0) { $parts += "${hours}시간" }
  if ($minutes -gt 0) { $parts += "${minutes}분" }
  if ($seconds -gt 0 -or $parts.Count -eq 0) { $parts += "${seconds}초" }
  $lblClearHuman.Text = '= ' + ($parts -join ' ')
}
$numClearWait.Add_ValueChanged($updateClearHuman)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = '설정 저장'
$btnSave.Location = New-Object System.Drawing.Point(430, 108)
$btnSave.Size = New-Object System.Drawing.Size(108, 30)
$grpSettings.Controls.Add($btnSave)

$lblSaveInfo = New-Object System.Windows.Forms.Label
$lblSaveInfo.Text = ''
$lblSaveInfo.Location = New-Object System.Drawing.Point(205, 82)
$lblSaveInfo.Size = New-Object System.Drawing.Size(220, 20)
$lblSaveInfo.ForeColor = [System.Drawing.Color]::SeaGreen
$grpSettings.Controls.Add($lblSaveInfo)

# --- 로그 ---
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 498)
$txtLog.Size = New-Object System.Drawing.Size(554, 300)
# 창 크기를 조절하면 로그 영역이 함께 늘어나고 줄어듭니다
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 30)
$txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($txtLog)

$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = 'Log 폴더 열기'
$btnOpenLog.Location = New-Object System.Drawing.Point(15, 806)
$btnOpenLog.Size = New-Object System.Drawing.Size(110, 28)
$btnOpenLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($btnOpenLog)

$lblFontSize = New-Object System.Windows.Forms.Label
$lblFontSize.Text = '로그 글자 크기:'
$lblFontSize.Location = New-Object System.Drawing.Point(140, 812)
$lblFontSize.Size = New-Object System.Drawing.Size(88, 20)
$lblFontSize.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($lblFontSize)

$numFontSize = New-Object System.Windows.Forms.NumericUpDown
$numFontSize.Location = New-Object System.Drawing.Point(230, 809)
$numFontSize.Size = New-Object System.Drawing.Size(48, 24)
$numFontSize.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$numFontSize.Minimum = 8
$numFontSize.Maximum = 20
$numFontSize.Value = 9
$form.Controls.Add($numFontSize)

$numFontSize.Add_ValueChanged({
    # Font 속성을 바꾸면 기존 색상 서식이 리셋되므로, 색을 보존하는 확대 배율로 크기를 조절합니다
    $txtLog.ZoomFactor = [float]([int]$numFontSize.Value / 9.0)
    if ($script:uiReady) {
      # 선택한 크기를 config 에 저장해 다음 실행에도 유지
      $cfg = Read-Config
      if ($cfg) {
        if ($cfg.PSObject.Properties['ui']) {
          if ($cfg.ui.PSObject.Properties['logFontSize']) { $cfg.ui.logFontSize = [int]$numFontSize.Value }
          else { $cfg.ui | Add-Member -NotePropertyName 'logFontSize' -NotePropertyValue ([int]$numFontSize.Value) }
        } else {
          $cfg | Add-Member -NotePropertyName 'ui' -NotePropertyValue ([pscustomobject]@{ logFontSize = [int]$numFontSize.Value })
        }
        Save-Config $cfg
      }
    }
  })

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = '로그 지우기'
$btnClearLog.Location = New-Object System.Drawing.Point(295, 806)
$btnClearLog.Size = New-Object System.Drawing.Size(100, 28)
$btnClearLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($btnClearLog)

# 앱 버전 표시 (로그 지우기 버튼 옆 - 제목줄보다 눈에 잘 띄는 위치)
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "v$appVersion"
$lblVersion.Location = New-Object System.Drawing.Point(405, 812)
$lblVersion.Size = New-Object System.Drawing.Size(160, 20)
$lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblVersion.ForeColor = [System.Drawing.Color]::DimGray
$lblVersion.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($lblVersion)

$btnClearLog.Add_Click({
    $txtLog.Clear()
    # Clear() 후에는 확대 배율이 1.0으로 초기화되므로 다시 적용합니다
    $txtLog.ZoomFactor = [float]([int]$numFontSize.Value / 9.0)
    # 화면 표시만 지웁니다. Log 폴더의 파일 기록은 그대로 남습니다.
  })

# ============================================================
#  동작 로직
# ============================================================
function Add-ColoredLogLine {
  param([string]$Text)

  # 내용에 따라 색을 입혀 로그창에 한 줄 추가합니다.
  $lineColor = [System.Drawing.Color]::Gainsboro                                  # 기본(회백색)
  if ($Text -match '\[오류\]|오류 종료|실패') {
    $lineColor = [System.Drawing.Color]::FromArgb(255, 110, 110)                  # 오류 = 빨강
  } elseif ($Text -match '\[경고\]') {
    $lineColor = [System.Drawing.Color]::Gold                                     # 경고 = 노랑
  } elseif ($Text -match '\[안내\]|\[진단\]|\[중단\]') {
    $lineColor = [System.Drawing.Color]::SkyBlue                                  # 안내 = 하늘색
  } elseif ($Text -match '\[완료\]|회차 완료|===|복귀 확인') {
    $lineColor = [System.Drawing.Color]::LightGreen                               # 완료 = 초록
  } elseif ($Text -match '\[준비\]') {
    $lineColor = [System.Drawing.Color]::MediumPurple                             # 준비 = 보라
  }
  $txtLog.SelectionStart = $txtLog.TextLength
  $txtLog.SelectionLength = 0
  $txtLog.SelectionColor = $lineColor
  $txtLog.AppendText($Text + "`r`n")
  $txtLog.SelectionColor = $txtLog.ForeColor
  $txtLog.ScrollToCaret()
}

function Add-GuiLog {
  param([string]$Message)
  Add-ColoredLogLine "$(Get-Date -Format 'HH:mm:ss') $Message"
}

function Load-SettingsToUi {
  $cfg = Read-Config
  if (-not $cfg) {
    $causeText = $(if ($script:configReadError) { " (원인: $($script:configReadError))" } else { '' })
    Add-GuiLog "config.json 을 읽지 못해 기본값으로 표시합니다.$causeText"
    return
  }
  $spaceEntry = Get-KeyEntry $cfg 32
  $foodEntry = Get-KeyEntry $cfg 66
  if ($spaceEntry -and $spaceEntry.PSObject.Properties['enabled']) { $chkSpace.Checked = [bool]$spaceEntry.enabled } else { $chkSpace.Checked = $true }
  if ($foodEntry -and $foodEntry.PSObject.Properties['enabled']) { $chkFood.Checked = [bool]$foodEntry.enabled } else { $chkFood.Checked = $true }
  # 자동부활 설정 복원 (revive 항목이 없던 예전 config 는 기본 켜짐)
  if ($cfg.PSObject.Properties['revive'] -and $cfg.revive.PSObject.Properties['enabled']) {
    $chkRevive.Checked = [bool]$cfg.revive.enabled
  } else {
    $chkRevive.Checked = $true
  }
  # 저장된 선택 던전 복원 (해당 라디오가 활성화된 경우에만)
  try {
    $savedDungeon = [string]$cfg.dungeons.selected
    if ($savedDungeon -eq '광기의 동굴' -and $rbDgMadness.Enabled) { $rbDgMadness.Checked = $true }
    elseif ($savedDungeon -eq '흩어진 물길' -and $rbDgScattered.Enabled) { $rbDgScattered.Checked = $true }
    else { $rbDgHeosang.Checked = $true }
  } catch { $rbDgHeosang.Checked = $true }
  # 저장된 입장 방식 복원
  try {
    if ([string]$cfg.dungeons.mode -eq 'party') { $rbModeParty.Checked = $true } else { $rbModeSolo.Checked = $true }
  } catch { $rbModeSolo.Checked = $true }
  # 저장된 어비스 매칭 방식 복원 (함께하기 전용 설정).
  # 과도기 config 는 파티 상태가 dungeons.partyState 로 분리 저장된 버전이 있었으므로
  # 그 값이 파티(파티장)/(파티원)이면 매칭으로 되돌려 해석합니다.
  try {
    $savedMatching = [string]$cfg.dungeons.matching
    $legacyPartyState = [string]$cfg.dungeons.partyState
    if ($legacyPartyState -eq '파티(파티장)' -or $legacyPartyState -eq '파티(파티원)') {
      $savedMatching = $legacyPartyState
    }
    switch ($savedMatching) {
      '파티찾기' { $rbAbyssFindParty.Checked = $true }
      '파티(파티장)' { $rbAbyssPartyLead.Checked = $true }
      '파티(파티원)' { $rbAbyssPartyMember.Checked = $true }
      default { $rbAbyssChance.Checked = $true }
    }
  } catch { $rbAbyssChance.Checked = $true }
  # 저장된 콘텐츠 카테고리 복원 (abyss = 어비스 / dungeon = 던전 / hunting = 사냥터)
  try {
    switch ([string]$cfg.contentCategory) {
      'dungeon' { $rbCatDungeon.Checked = $true }
      'hunting' { $rbCatHunting.Checked = $true }
      default   { $rbCatAbyss.Checked = $true }
    }
  } catch { $rbCatAbyss.Checked = $true }
  # 저장된 사냥터 설정 복원
  try {
    $ht = $cfg.huntingGround
    if ($ht) {
      switch ([string]$ht.difficulty) {
        '어려움'      { $rbHtHard.Checked = $true }
        '매우 어려움' { $rbHtVeryHard.Checked = $true }
        default       { $rbHtNormal.Checked = $true }
      }
      $chkHtCoin.Checked = [bool]$ht.useOffering
      $chkHtDoubleLoot.Checked = [bool]$ht.doubleLoot
      # '소탕만 계속'은 더블 루팅이 켜져 있을 때만 의미가 있으므로 함께 확인합니다
      try { $chkHtLootFallback.Checked = ([bool]$ht.continueSweepOnly -and $chkHtDoubleLoot.Checked) } catch { $chkHtLootFallback.Checked = $false }
      if ([string]$ht.matching -eq '바로 입장') { $rbHtDirect.Checked = $true } else { $rbHtParty.Checked = $true }
    }
  } catch { }
  # 저장된 일반 던전 설정 복원
  try {
    $nd = $cfg.normalDungeon
    if ($nd) {
      if ([string]$nd.difficulty -eq '어려움') { $rbNdHard.Checked = $true } else { $rbNdNormal.Checked = $true }
      $stageValue = [string]$nd.stage
      if ($stageValue) {
        if (-not $cboNdStage.Items.Contains($stageValue)) { [void]$cboNdStage.Items.Add($stageValue) }
        $cboNdStage.SelectedItem = $stageValue
      }
      $chkNdCoin.Checked = [bool]$nd.useSilverCoin
      $chkNdDoubleLoot.Checked = [bool]$nd.doubleLoot
      try { $chkNdCoinFallback.Checked = [bool]$nd.continueWithoutCoin } catch { $chkNdCoinFallback.Checked = $false }
      # '소탕만 계속'은 더블 루팅이 켜져 있을 때만 유효 (꺼져 있으면 저장값과 무관하게 해제)
      try { $chkNdLootFallback.Checked = ([bool]$nd.continueSweepOnly -and $chkNdDoubleLoot.Checked) } catch { $chkNdLootFallback.Checked = $false }
      if ([string]$nd.matching -eq '우연한 만남') { $rbNdChance.Checked = $true } else { $rbNdFindParty.Checked = $true }
    }
  } catch { }
  # 저장된 난이도 복원 (없거나 빈 값이면 '게임 그대로'. 목록에 없는 이름이 저장돼
  # 있으면 - 예: config 에 직접 적은 새 난이도 - 목록에 추가한 뒤 선택합니다.
  # 단, 지옥 난이도는 함께하기 전용이라 혼자하기 상태면 '게임 그대로'로 되돌립니다)
  try {
    $savedDifficulty = [string]$cfg.dungeons.difficulty
    if ($savedDifficulty) {
      if ($cboDifficulty.Items.Contains($savedDifficulty)) {
        $cboDifficulty.SelectedItem = $savedDifficulty
      } elseif ($rbModeSolo.Checked -and $savedDifficulty -match '^지옥') {
        $cboDifficulty.SelectedIndex = 0
      } else {
        [void]$cboDifficulty.Items.Add($savedDifficulty)
        $cboDifficulty.SelectedItem = $savedDifficulty
      }
    } else {
      $cboDifficulty.SelectedIndex = 0
    }
  } catch { $cboDifficulty.SelectedIndex = 0 }
  try { $numClearWait.Value = [int]$cfg.timeoutsSeconds.dungeonClear } catch { }
  try { $numCount.Value = [int]$cfg.repeat.defaultCount } catch { }
  try { $numFontSize.Value = [int]$cfg.ui.logFontSize } catch { }
}

function Save-SettingsFromUi {
  $cfg = Read-Config
  if (-not $cfg) {
    $causeText = $(if ($script:configReadError) { " (원인: $($script:configReadError))" } else { '' })
    Add-GuiLog "[오류] config.json 을 읽지 못해 저장할 수 없습니다.$causeText"
    return $false
  }
  $spaceEntry = Get-KeyEntry $cfg 32
  $foodEntry = Get-KeyEntry $cfg 66
  if ($spaceEntry) { $spaceEntry.enabled = [bool]$chkSpace.Checked }
  if ($foodEntry) { $foodEntry.enabled = [bool]$chkFood.Checked }
  # 자동부활(불사의 가루) 설정 저장. revive 항목이 없던 예전 config 에는 새로 만들어 기록합니다.
  if ($cfg.PSObject.Properties['revive']) {
    if ($cfg.revive.PSObject.Properties['enabled']) { $cfg.revive.enabled = [bool]$chkRevive.Checked }
    else { $cfg.revive | Add-Member -NotePropertyName 'enabled' -NotePropertyValue ([bool]$chkRevive.Checked) }
  } else {
    $cfg | Add-Member -NotePropertyName 'revive' -NotePropertyValue ([pscustomobject]@{
      '_설명'  = '던전에서 캐릭터가 행동불능(사망)이 되면 자동으로 부활하는 기능입니다.'
      enabled  = [bool]$chkRevive.Checked
      key      = 82
      maxPerCycle = 10
    })
  }
  # 창 자동 정렬과 가림 자동 복구는 안정 동작의 핵심이라 항상 켜둡니다.
  # 가림 자동 복구는 "실제로 가려짐 + 사용자 자리 비움"일 때만 동작하므로 성가실 일이 없습니다.
  # 아래 섹션들은 구버전/수동 편집 config 에 없을 수 있으므로, 없으면 만들어 넣어 저장이 죽지 않게 합니다.
  if (-not $cfg.PSObject.Properties['window']) { $cfg | Add-Member -NotePropertyName 'window' -NotePropertyValue ([pscustomobject]@{}) }
  if ($cfg.window.PSObject.Properties['normalize']) { $cfg.window.normalize = $true }
  else { $cfg.window | Add-Member -NotePropertyName 'normalize' -NotePropertyValue $true }
  # 창 크기 모드: GUI 는 nearest(사용자 크기 유지 + 비율 보정)를 사용합니다.
  # '권장 창 모드' 버튼은 즉시 1회 적용 방식이라 상시 모드가 필요 없습니다.
  # (과거 체크박스 시절 저장된 recommended 는 nearest 로 되돌리고, 직접 적은 fixed 는 유지)
  if ($cfg.window.PSObject.Properties['mode']) {
    if ([string]$cfg.window.mode -eq 'recommended') { $cfg.window.mode = 'nearest' }
  } else {
    $cfg.window | Add-Member -NotePropertyName 'mode' -NotePropertyValue 'nearest'
  }
  # RDP 자동 전환은 config 값(rdp.autoConsoleRedirect)을 존중합니다. false 로 바꾸면
  # 다음 시작/저장 때 예약 작업이 제거됩니다 (config 주석의 안내와 동작을 일치시킴).
  if (-not $cfg.PSObject.Properties['rdp']) { $cfg | Add-Member -NotePropertyName 'rdp' -NotePropertyValue ([pscustomobject]@{}) }
  if (-not $cfg.rdp.PSObject.Properties['autoConsoleRedirect']) { $cfg.rdp | Add-Member -NotePropertyName 'autoConsoleRedirect' -NotePropertyValue $true }
  # 가림 복구 주기: 문서대로 '0 = 기능 끄기'를 허용합니다. 키가 아예 없을 때만 기본 8초를 넣습니다.
  if (-not $cfg.PSObject.Properties['focus']) { $cfg | Add-Member -NotePropertyName 'focus' -NotePropertyValue ([pscustomobject]@{}) }
  if (-not $cfg.focus.PSObject.Properties['refocusEverySeconds']) { $cfg.focus | Add-Member -NotePropertyName 'refocusEverySeconds' -NotePropertyValue 8 }
  if (-not $cfg.PSObject.Properties['timeoutsSeconds']) { $cfg | Add-Member -NotePropertyName 'timeoutsSeconds' -NotePropertyValue ([pscustomobject]@{}) }
  if ($cfg.timeoutsSeconds.PSObject.Properties['dungeonClear']) { $cfg.timeoutsSeconds.dungeonClear = [int]$numClearWait.Value }
  else { $cfg.timeoutsSeconds | Add-Member -NotePropertyName 'dungeonClear' -NotePropertyValue ([int]$numClearWait.Value) }
  if (-not $cfg.PSObject.Properties['repeat']) { $cfg | Add-Member -NotePropertyName 'repeat' -NotePropertyValue ([pscustomobject]@{}) }
  if ($cfg.repeat.PSObject.Properties['defaultCount']) { $cfg.repeat.defaultCount = [int]$numCount.Value }
  else { $cfg.repeat | Add-Member -NotePropertyName 'defaultCount' -NotePropertyValue ([int]$numCount.Value) }

  # 선택된 던전을 config 에 기록 (워커가 이 값으로 카드 클릭 대상을 정함)
  $dungeonName = '허상의 정박지'
  if ($rbDgMadness.Checked) { $dungeonName = '광기의 동굴' }
  elseif ($rbDgScattered.Checked) { $dungeonName = '흩어진 물길' }
  $modeValue = 'solo'
  if ($rbModeParty.Checked) { $modeValue = 'party' }
  # 선택된 난이도 ('' = 게임 그대로, 난이도 클릭 안 함)
  $difficultyValue = ''
  if ($cboDifficulty.SelectedIndex -gt 0 -and $cboDifficulty.SelectedItem) {
    $difficultyValue = [string]$cboDifficulty.SelectedItem
  }
  # 콘텐츠 카테고리 저장 (abyss = 어비스 / dungeon = 던전 / hunting = 사냥터)
  $categoryValue = 'abyss'
  if ($rbCatDungeon.Checked) { $categoryValue = 'dungeon' }
  elseif ($rbCatHunting.Checked) { $categoryValue = 'hunting' }
  if ($cfg.PSObject.Properties['contentCategory']) { $cfg.contentCategory = $categoryValue }
  else { $cfg | Add-Member -NotePropertyName 'contentCategory' -NotePropertyValue $categoryValue }
  # 던전 설정 저장 (전체 자동화: 선택 → 옵션 → 입장 → 클리어 → 다시 하기 반복)
  $ndSettings = [pscustomobject]@{
    '_설명'       = "'던전' 카테고리 전용 설정입니다 (던전 전체 자동화 - 은동전/더블 루팅/매칭 포함)"
    difficulty    = $(if ($rbNdHard.Checked) { '어려움' } else { '일반' })
    stage         = [string]$cboNdStage.SelectedItem
    useSilverCoin = [bool]$chkNdCoin.Checked
    doubleLoot    = [bool]($chkNdCoin.Checked -and $chkNdDoubleLoot.Checked)
    '_continueWithoutCoin' = 'true면 은동전이 10개 미만(소탕 불가)일 때 소탕을 해제하고 미사용(도전)으로 계속 반복합니다'
    continueWithoutCoin = [bool]($chkNdCoin.Checked -and $chkNdCoinFallback.Checked)
    '_continueSweepOnly' = 'true면 은동전이 10~19개(더블 루팅 불가, 소탕은 가능)일 때 더블 루팅만 끄고 소탕(10개)으로 계속합니다'
    continueSweepOnly   = [bool]($chkNdCoin.Checked -and $chkNdDoubleLoot.Checked -and $chkNdLootFallback.Checked)
    matching      = $(if ($rbNdChance.Checked) { '우연한 만남' } else { '파티찾기' })
  }
  if ($cfg.PSObject.Properties['normalDungeon']) { $cfg.normalDungeon = $ndSettings }
  else { $cfg | Add-Member -NotePropertyName 'normalDungeon' -NotePropertyValue $ndSettings }
  # 사냥터 설정 저장 (특정 사냥터에 매이지 않음 - 원하는 사냥터 첫 화면을 열어 두고 시작)
  $htSettings = [pscustomobject]@{
    '_설명'      = "'사냥터' 카테고리 설정입니다. 원하는 사냥터의 첫 화면을 열어 두고 시작하면 어느 사냥터든 동작합니다"
    difficulty   = $(if ($rbHtVeryHard.Checked) { '매우 어려움' } elseif ($rbHtHard.Checked) { '어려움' } else { '일반' })
    useOffering  = [bool]$chkHtCoin.Checked
    doubleLoot   = [bool]($chkHtCoin.Checked -and $chkHtDoubleLoot.Checked)
    '_continueSweepOnly' = 'true면 은동전이 10~19개(더블 루팅 불가, 소탕은 가능)일 때 더블 루팅만 끄고 소탕(10개)으로 계속합니다. 10개 미만이면 옵션과 무관하게 사냥터에서 나가고 자동화를 마칩니다'
    continueSweepOnly   = [bool]($chkHtCoin.Checked -and $chkHtDoubleLoot.Checked -and $chkHtLootFallback.Checked)
    matching     = $(if ($rbHtDirect.Checked) { '바로 입장' } else { '파티찾기' })
  }
  if ($cfg.PSObject.Properties['huntingGround']) { $cfg.huntingGround = $htSettings }
  else { $cfg | Add-Member -NotePropertyName 'huntingGround' -NotePropertyValue $htSettings }
  $abyssMatchingValue = '우연한 만남'
  if ($rbAbyssFindParty.Checked) { $abyssMatchingValue = '파티찾기' }
  elseif ($rbAbyssPartyLead.Checked) { $abyssMatchingValue = '파티(파티장)' }
  elseif ($rbAbyssPartyMember.Checked) { $abyssMatchingValue = '파티(파티원)' }
  if ($cfg.PSObject.Properties['dungeons']) {
    $cfg.dungeons.selected = $dungeonName
    if ($cfg.dungeons.PSObject.Properties['mode']) { $cfg.dungeons.mode = $modeValue }
    else { $cfg.dungeons | Add-Member -NotePropertyName 'mode' -NotePropertyValue $modeValue }
    if ($cfg.dungeons.PSObject.Properties['difficulty']) { $cfg.dungeons.difficulty = $difficultyValue }
    else { $cfg.dungeons | Add-Member -NotePropertyName 'difficulty' -NotePropertyValue $difficultyValue }
    if ($cfg.dungeons.PSObject.Properties['matching']) { $cfg.dungeons.matching = $abyssMatchingValue }
    else { $cfg.dungeons | Add-Member -NotePropertyName 'matching' -NotePropertyValue $abyssMatchingValue }
    # 과도기 버전이 남긴 partyState 키는 더 이상 쓰지 않으므로 제거합니다 (매칭에 통합)
    if ($cfg.dungeons.PSObject.Properties['partyState']) { $cfg.dungeons.PSObject.Properties.Remove('partyState') }
    if ($cfg.dungeons.PSObject.Properties['_partyState']) { $cfg.dungeons.PSObject.Properties.Remove('_partyState') }
    # 세 던전 모두 전체 자동화(full)로 보정합니다 (구버전 config 의 detail 값도 갱신)
    try {
      foreach ($profileName in @($cfg.dungeons.profiles.PSObject.Properties.Name)) {
        $profileNode = $cfg.dungeons.profiles.$profileName
        if ($profileNode.PSObject.Properties['stage']) {
          $profileNode.stage = 'full'
        } else {
          $profileNode | Add-Member -NotePropertyName 'stage' -NotePropertyValue 'full'
        }
      }
    } catch { }
  } else {
    # 예전 config 에는 dungeons 항목이 없으므로 기본 프로파일과 함께 새로 만듭니다
    $defaultProfiles = [pscustomobject]@{
      '허상의 정박지' = [pscustomobject]@{ card = @(956, 157); stage = 'full'; match = '정박' }
      '광기의 동굴'   = [pscustomobject]@{ card = @(956, 272); stage = 'full'; match = '광기' }
      '흩어진 물길'   = [pscustomobject]@{ card = @(956, 387); stage = 'full'; match = '물길' }
    }
    $cfg | Add-Member -NotePropertyName 'dungeons' -NotePropertyValue ([pscustomobject]@{
        selected   = $dungeonName
        mode       = $modeValue
        difficulty = $difficultyValue
        matching   = $abyssMatchingValue
        profiles   = $defaultProfiles
      })
  }

  Save-Config $cfg
  return $true
}

function Set-UiRunning {
  param([bool]$IsRunning)
  $script:running = $IsRunning
  $btnStart.Enabled = -not $IsRunning
  $btnSafeStop.Enabled = $IsRunning
  $btnKill.Enabled = $IsRunning
  $grpRepeat.Enabled = -not $IsRunning
  $grpContent.Enabled = -not $IsRunning
  $grpContentDetail.Enabled = -not $IsRunning
}

function Test-TimeAllowsNextCycle {
  # 시간 지정 모드에서 "지금 시작하면 목표 시각 안에 끝날 수 있는지" 판단합니다.
  # 판단 기준: 현재 시각 + 클리어 대기 설정 시간 <= 목표 시각
  if ($null -eq $script:targetTime) { return $true }
  $estimatedEnd = (Get-Date).AddSeconds([int]$numClearWait.Value)
  return ($estimatedEnd -le $script:targetTime)
}

function Start-NextCycle {
  $cycleNumber = $script:completedCycles + 1
  # 지난 세션(또는 직전 회차)의 로그 파일이 남아 있으면, 워커가 새로 쓰기 전에
  # GUI 타이머가 그 내용을 '새 로그'로 착각해 화면에 다시 출력합니다.
  # 워커 시작 전에 파일을 치워 과거 로그가 다시 뜨지 않게 하되, 그냥 지우지 않고
  # run_시각.log 로 보관해 지난 회차 로그를 최근 20개까지 남깁니다 (오류 세트 보관 개수와 동일).
  try {
    if (Test-Path -LiteralPath $workerLog) {
      $archiveStamp = (Get-Item -LiteralPath $workerLog).LastWriteTime.ToString('yyyyMMdd_HHmmss')
      $archivePath = Join-Path $scriptRoot ("Log\run_{0}.log" -f $archiveStamp)
      Move-Item -LiteralPath $workerLog -Destination $archivePath -Force -ErrorAction Stop
      # 보관 개수(20개) 초과분은 오래된 것부터 삭제
      $oldRunLogs = @(Get-ChildItem -Path (Join-Path $scriptRoot 'Log') -Filter 'run_*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20)
      foreach ($oldLog in $oldRunLogs) { Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction SilentlyContinue }
    }
    $script:logSeen = 0
  } catch {
    # 파일이 잠겨 있는 등 이동이 안 되면, 현재 줄 수까지를 '이미 본 것'으로 처리합니다.
    # (워커가 파일을 새로 쓰면 줄 수가 줄어들어 타이머의 리셋 로직이 처음부터 다시 읽습니다)
    $existing = Read-LogLines $workerLog
    $script:logSeen = if ($null -ne $existing) { $existing.Count } else { 0 }
  }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $workerScript + '"'))
  $script:worker = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arguments -PassThru
  $statusSuffix = ''
  if ($null -ne $script:targetTime) { $statusSuffix = " ($($script:targetTime.ToString('HH:mm')) 까지)" }
  $lblStatus.Text = "${cycleNumber}회차 실행 중...$statusSuffix"
  $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
  Add-GuiLog "=== ${cycleNumber}회차 시작 ==="
}

function Stop-AllRun {
  param([string]$Reason)
  if ($script:worker -and -not $script:worker.HasExited) {
    try { $script:worker.Kill(); $script:worker.WaitForExit() } catch { }
    # Kill 시점이 키/마우스 '누름-뗌' 사이였을 수 있으므로 입력 상태를 정리합니다
    Release-StuckInput
  }
  $script:worker = $null
  Set-UiRunning $false
  $script:stopRequested = $false
  $script:targetTime = $null
  $btnSafeStop.Text = ("안전 중지(F9)" + [Environment]::NewLine + "(회차 완료 후)")
  Remove-Item -LiteralPath $safeStopFlag -Force -ErrorAction SilentlyContinue
  # 화면 유지 신호 해제 (평소 절전 설정으로 복귀)
  [Win32.PowerState]::SetThreadExecutionState($script:esRelease) | Out-Null
  $lblStatus.Text = "중지됨 - $Reason (완료: $($script:completedCycles)회)"
  $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
  Add-GuiLog "중지: $Reason"
}

# --- 타이머: 워커 상태 + 로그 tail ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 600
$timer.Add_Tick({
    # 워커 로그 tail
    if ($script:running) {
      $lines = Read-LogLines $workerLog
      if ($null -ne $lines) {
        if ($lines.Count -lt $script:logSeen) { $script:logSeen = 0 }
        for ($i = $script:logSeen; $i -lt $lines.Count; $i++) {
          Add-ColoredLogLine ('  ' + $lines[$i])
        }
        $script:logSeen = $lines.Count
      }
      if ($txtLog.TextLength -gt 200000) {
        $txtLog.Text = $txtLog.Text.Substring($txtLog.TextLength - 100000)
        $txtLog.SelectionStart = $txtLog.TextLength
        # Text 교체 후 확대 배율이 초기화될 수 있어 다시 적용합니다
        $txtLog.ZoomFactor = [float]([int]$numFontSize.Value / 9.0)
      }
    }

    # 워커 종료 처리
    if ($script:running -and $script:worker -and $script:worker.HasExited) {
      $exitCode = $script:worker.ExitCode
      $script:worker = $null
      if ($exitCode -eq 0) {
        $script:preparedStreak = 0
        $script:completedCycles++
        Add-GuiLog "=== $($script:completedCycles)회차 완료 ==="
        $reachedTarget = ($script:targetCycles -gt 0 -and $script:completedCycles -ge $script:targetCycles)
        if ($script:stopRequested) {
          Stop-AllRun '안전 중지'
        } elseif ($reachedTarget) {
          Stop-AllRun '지정 횟수 완료'
        } elseif (-not (Test-TimeAllowsNextCycle)) {
          # 남은 시간이 클리어 대기 시간보다 짧으면 다음 회차를 시작하지 않습니다
          $targetText = $script:targetTime.ToString('HH:mm')
          Add-GuiLog "지정 시간($targetText)까지 남은 시간이 부족해 다음 회차를 시작하지 않습니다."
          Stop-AllRun "지정 시간($targetText) 도달"
        } else {
          Start-NextCycle
        }
      } elseif ($exitCode -eq 10) {
        # 준비 실행(화면 복귀만 수행, 던전 미실행): 회차로 세지 않고 곧바로 본 회차를 시작합니다.
        # 이렇게 해야 횟수 지정 모드에서 실제 던전 실행 횟수가 요청보다 적어지지 않습니다.
        $script:preparedStreak++
        Add-GuiLog '[안내] 화면 복귀(준비 실행)만 수행 - 회차로 세지 않고 이어서 시작합니다'
        if ($script:stopRequested) {
          Stop-AllRun '안전 중지'
        } elseif ($script:preparedStreak -ge 3) {
          # 화면 오판 등으로 준비 실행만 반복되는 무한 루프 방지 (레거시 컨트롤러와 동일한 상한)
          Stop-AllRun '준비 실행(화면 복귀)이 3회 연속 반복 - 게임 화면 상태를 확인해 주세요'
          $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        } elseif (-not (Test-TimeAllowsNextCycle)) {
          $targetText = $script:targetTime.ToString('HH:mm')
          Stop-AllRun "지정 시간($targetText) 도달"
        } else {
          Start-NextCycle
        }
      } elseif ($exitCode -eq 2) {
        # 다른 인스턴스가 이미 실행 중(뮤텍스 충돌): 이중 조작을 피하기 위해 이 GUI는 멈춥니다
        Stop-AllRun '다른 자동화 인스턴스가 이미 실행 중 (중복 실행 방지) - 작업 관리자에서 powershell.exe 를 종료한 뒤 다시 시작해 주세요'
        $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
      } elseif ($exitCode -eq 3) {
        # 미개발 구간 도달: 구현된 데까지 완료하고 정상 정지 (오류 아님, 상세는 로그 참고)
        Stop-AllRun '구현된 구간까지 완료 - 정지 (자세한 내용은 로그 참고)'
        $lblStatus.ForeColor = [System.Drawing.Color]::SteelBlue
      } elseif ($exitCode -eq 4) {
        # 조건 충족에 의한 정상 정지 (예: 은동전 소진 + '소진 시 계속' 옵션 꺼짐)
        Stop-AllRun '조건 충족으로 정지 - 은동전 소진 등 (자세한 내용은 로그 참고)'
        $lblStatus.ForeColor = [System.Drawing.Color]::SteelBlue
      } else {
        Stop-AllRun "오류 종료(코드 $exitCode) - 로그 확인"
        $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
      }
    }
  })

# --- 버튼 이벤트 ---
$btnStart.Add_Click({
    if ($rbCatDungeon.Checked) {
      # 시작 화면 요구사항 안내: 던전은 구역 선택 화면(또는 진입 옵션/결과 화면)에서 시작해야 합니다
      Add-GuiLog '[안내] 던전 자동화: 원하는 던전의 구역 선택 화면(또는 진입 옵션 화면)을 열어 두고 시작하세요. 은동전 옵션을 켰다면 실제로 은동전이 소모됩니다.'
    }
    if (-not (Test-Path -LiteralPath $workerScript)) {
      [System.Windows.Forms.MessageBox]::Show('mabinogi_run_once.ps1 을 찾지 못했습니다.', '오류') | Out-Null
      return
    }
    if (-not (Save-SettingsFromUi)) { return }
    $cleanup = Stop-ExistingAutomation
    if ($cleanup.Killed -gt 0) {
      Add-GuiLog "기존 자동화 프로세스 $($cleanup.Killed)개를 종료했습니다."
      # 강제 종료된 워커가 키/마우스 '누름-뗌' 사이였을 수 있으므로 입력 상태를 정리합니다
      Release-StuckInput
    }
    if ($cleanup.Failed -gt 0) { Add-GuiLog "[경고] 기존 자동화 프로세스 $($cleanup.Failed)개를 종료하지 못했습니다 - 새 회차가 '중복 실행'으로 멈추면 작업 관리자에서 powershell.exe 를 직접 종료해 주세요." }
    # 지난 세션의 안전 중지 신호가 남아 있으면 제거 (남아 있으면 첫 회차가 조기 종료됨)
    Remove-Item -LiteralPath $safeStopFlag -Force -ErrorAction SilentlyContinue
    $btnSafeStop.Text = ("안전 중지(F9)" + [Environment]::NewLine + "(회차 완료 후)")
    # RDP 자동 전환은 config 의 rdp.autoConsoleRedirect 값을 따릅니다 (false = 예약 작업 제거)
    $rdpEnable = $true
    $cfgNow = Read-Config
    if ($cfgNow -and $cfgNow.PSObject.Properties['rdp'] -and $cfgNow.rdp.PSObject.Properties['autoConsoleRedirect']) {
      $rdpEnable = [bool]$cfgNow.rdp.autoConsoleRedirect
    }
    $rdpResult = Sync-RdpRedirectTask -Enable $rdpEnable
    if ($rdpResult -eq 'installed') { Add-GuiLog 'RDP 자동 전환이 설치됐습니다. RDP 창을 닫아도 계속 돕니다.' }
    elseif ($rdpResult -eq 'removed') { Add-GuiLog 'RDP 자동 전환 예약 작업을 제거했습니다 (config 의 rdp.autoConsoleRedirect = false). RDP 창을 닫으면 캡처가 멈출 수 있습니다.' }
    elseif ($rdpResult -like 'error*') { Add-GuiLog "RDP 자동 전환 설정 실패: $rdpResult" }

    $script:completedCycles = 0
    $script:stopRequested = $false
    $script:preparedStreak = 0
    $script:targetTime = $null
    if ($rbCount.Checked) { $script:targetCycles = [int]$numCount.Value } else { $script:targetCycles = 0 }
    if ($rbTime.Checked) {
      # 목표 시각 계산: 오늘 그 시각, 이미 지났으면 내일 그 시각
      $candidate = (Get-Date).Date.Add($dtpUntil.Value.TimeOfDay)
      if ($candidate -le (Get-Date)) { $candidate = $candidate.AddDays(1) }
      $script:targetTime = $candidate
      if (-not (Test-TimeAllowsNextCycle)) {
        Add-GuiLog "[안내] 지정 시간($($script:targetTime.ToString('HH:mm')))까지 남은 시간이 클리어 대기($([int]$numClearWait.Value)초)보다 짧아 시작할 수 없습니다."
        $script:targetTime = $null
        return
      }
      Add-GuiLog "시간 지정 모드: $($script:targetTime.ToString('MM-dd HH:mm')) 까지 반복합니다."
    }
    # 실행 중에는 화면 꺼짐/절전을 막습니다 (감지가 화면 렌더링에 의존)
    [Win32.PowerState]::SetThreadExecutionState($script:esKeepAwake) | Out-Null
    Set-UiRunning $true
    Start-NextCycle
  })

$btnSafeStop.Add_Click({
    # 토글 동작: 이미 예약된 상태에서 다시 누르면 예약을 취소하고 반복을 계속합니다.
    if ($script:stopRequested) {
      $script:stopRequested = $false
      Remove-Item -LiteralPath $safeStopFlag -Force -ErrorAction SilentlyContinue
      $btnSafeStop.Text = ("안전 중지(F9)" + [Environment]::NewLine + "(회차 완료 후)")
      $statusSuffix = ''
      if ($null -ne $script:targetTime) { $statusSuffix = " ($($script:targetTime.ToString('HH:mm')) 까지)" }
      $lblStatus.Text = "$($script:completedCycles + 1)회차 실행 중...$statusSuffix (안전 중지 취소됨)"
      $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
      Add-GuiLog '안전 중지 취소: 반복을 계속합니다.'
      return
    }
    $script:stopRequested = $true
    # 워커에게 신호 파일을 남깁니다: 던전에서 나와 밖(HUD)이 확인되면 어비스 선택 화면까지
    # 복귀하지 않고 그 시점에서 회차를 마칩니다.
    try {
      Set-Content -LiteralPath $safeStopFlag -Value 'stop' -Encoding ASCII
    } catch {
      # 신호 파일 생성 실패: 워커의 조기 종료 지점은 동작하지 않지만, GUI의 stopRequested 로
      # 이번 회차가 끝나는 시점에는 멈추므로 그 사실을 정확히 알립니다.
      Add-GuiLog "[경고] 안전 중지 신호 파일을 만들지 못했습니다($($_.Exception.Message)) - 진행 중인 회차가 완전히 끝나는 시점에 멈춥니다."
    }
    $btnSafeStop.Text = '안전 중지 취소(F9)'
    $lblStatus.Text = '안전 중지 예약됨 - 던전에서 나오는 대로 멈춥니다 (다시 누르면 취소)'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    Add-GuiLog '안전 중지 예약: 던전에서 나와 밖이 확인되면 멈춥니다. (버튼을 다시 누르면 취소)'
  })

$btnKill.Add_Click({ Stop-AllRun '즉시 중지' })

$btnSave.Add_Click({
    if (Save-SettingsFromUi) {
      # RDP 자동 전환은 config 의 rdp.autoConsoleRedirect 값을 따릅니다 (false = 예약 작업 제거)
      $rdpEnable = $true
      $cfgNow = Read-Config
      if ($cfgNow -and $cfgNow.PSObject.Properties['rdp'] -and $cfgNow.rdp.PSObject.Properties['autoConsoleRedirect']) {
        $rdpEnable = [bool]$cfgNow.rdp.autoConsoleRedirect
      }
      $rdpResult = Sync-RdpRedirectTask -Enable $rdpEnable
      $lblSaveInfo.Text = "저장됨 ($(Get-Date -Format 'HH:mm:ss'))"
      Add-GuiLog '설정이 저장됐습니다. 다음 회차부터 적용됩니다.'
      if ($rdpResult -eq 'installed') { Add-GuiLog 'RDP 자동 전환이 설치됐습니다.' }
      elseif ($rdpResult -eq 'removed') { Add-GuiLog 'RDP 자동 전환 예약 작업을 제거했습니다 (config 의 rdp.autoConsoleRedirect = false).' }
    }
  })

$btnOpenLog.Add_Click({
    $logDir = Join-Path $scriptRoot 'Log'
    if (Test-Path -LiteralPath $logDir) { Start-Process explorer.exe $logDir }
  })

$btnRecommendedWindow.Add_Click({
    Apply-RecommendedWindowSize
  })

$form.Add_FormClosing({
    param($formSender, $closeArgs)
    if ($script:running) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        '자동화가 실행 중입니다. 종료하면 현재 회차도 함께 중단됩니다. 종료할까요?',
        '종료 확인', [System.Windows.Forms.MessageBoxButtons]::YesNo)
      if ($answer -eq [System.Windows.Forms.DialogResult]::No) {
        $closeArgs.Cancel = $true
        return
      }
      if ($script:worker -and -not $script:worker.HasExited) {
        try { $script:worker.Kill() } catch { }
        Release-StuckInput
      }
      # 종료 전에 안전 중지 신호 파일을 정리합니다. 남겨 두면 컨트롤러 등 다른 실행 경로의
      # 다음 워커가 시작하자마자 조기 종료를 반복할 수 있습니다.
      Remove-Item -LiteralPath $safeStopFlag -Force -ErrorAction SilentlyContinue
    }
  })

# ----- 카테고리 전환: 상세 설정 패널 교체 + 그룹 높이/아래 요소 위치 재계산 -----
$updateCategoryPanels = {
  $isDungeon = $rbCatDungeon.Checked
  $isHunting = $rbCatHunting.Checked
  $isAbyss = (-not $isDungeon -and -not $isHunting)
  # 설명서 버튼 글자를 선택한 콘텐츠에 맞게 전환
  $btnManual.Text = $(if ($isDungeon) { '던전 설명서' } elseif ($isHunting) { '사냥터 설명서' } else { '어비스 설명서' })
  # 어비스용 패널 (함께하기일 때만 매칭 줄이 난이도 아래에 나타나고 던전 목록이 내려감)
  # 파티(파티원)은 난이도/던전 선택이 의미가 없어(파티장이 결정) 두 줄을 숨기고
  # 매칭 줄을 난이도 자리로 올립니다.
  $abyssPartyOn = $isAbyss -and $rbModeParty.Checked
  $abyssMemberOn = $abyssPartyOn -and $rbAbyssPartyMember.Checked
  $pnlMode.Visible = $isAbyss
  $pnlDifficulty.Visible = $isAbyss -and -not $abyssMemberOn
  $pnlAbyssMatching.Visible = $abyssPartyOn
  $pnlAbyssMatching.Top = $(if ($abyssMemberOn) { 52 } else { 84 })
  $pnlDungeon.Visible = $isAbyss -and -not $abyssMemberOn
  $pnlDungeon.Top = $(if ($abyssPartyOn) { 116 } else { 84 })
  # 던전용 패널 (더블 루팅은 은동전 사용 체크박스 옆, 소진 대응 줄은 은동전 사용 시에만 표시)
  $coinRowOn = $isDungeon -and $chkNdCoin.Checked
  $pnlNdDifficulty.Visible = $isDungeon
  $pnlNdStage.Visible = $isDungeon
  $pnlNdCoin.Visible = $isDungeon
  $pnlNdFallback.Visible = $coinRowOn
  $pnlNdParty.Visible = $isDungeon
  # 사냥터용 패널 (소진 대응 옵션 없음 - 은동전이 부족하면 나가고 자동화 종료)
  $pnlHtDifficulty.Visible = $isHunting
  $pnlHtCoin.Visible = $isHunting
  $pnlHtParty.Visible = $isHunting
  # 줄 수에 맞춰 배치/그룹 높이를 조절하고 아래 요소들을 내리거나 올립니다
  # (어비스/사냥터 3줄 = 122 / 어비스 함께하기·던전 4줄 = 150 / 던전 + 소진 대응 5줄 = 182)
  if ($isDungeon) {
    if ($coinRowOn) {
      $pnlNdParty.Top = 148
      $grpContentDetail.Height = 182
    } else {
      $pnlNdParty.Top = 116
      $grpContentDetail.Height = 150
    }
  } elseif ($abyssPartyOn) {
    # 파티원은 입장 방식 + 매칭 2줄만 남아 그룹을 줄입니다
    $grpContentDetail.Height = $(if ($abyssMemberOn) { 90 } else { 150 })
  } else {
    $grpContentDetail.Height = 122
  }
  $grpSettings.Top = $grpContentDetail.Bottom + 8
  $txtLog.Top = $grpSettings.Bottom + 8
  $logHeight = $btnOpenLog.Top - $txtLog.Top - 8
  if ($logHeight -lt 100) { $logHeight = 100 }
  $txtLog.Height = $logHeight
}
$rbCatAbyss.Add_CheckedChanged($updateCategoryPanels)
$rbCatDungeon.Add_CheckedChanged($updateCategoryPanels)
$rbCatHunting.Add_CheckedChanged($updateCategoryPanels)
# 파티(파티원) 선택/해제 시 난이도·던전 줄 표시가 바뀝니다 (라디오 전환은 상대 버튼의
# CheckedChanged 도 함께 발생하므로 파티원 버튼 하나에만 걸어도 모든 전환을 잡습니다)
$rbAbyssPartyMember.Add_CheckedChanged($updateCategoryPanels)

# ----- 시작 -----
# exe 업데이트로 좌표/구조가 바뀐 경우 사용자 설정만 옮겨 담아 config 를 자동 이전합니다
$script:configMigrated = Update-ConfigToLatest
Load-SettingsToUi
& $updateClearHuman
& $updateCategoryPanels
# --- 전역 단축키: F9 = 시작/안전 중지(토글), F10 = 즉시 중지 ---
# 게임 창에 포커스가 있어도 동작하도록 키 상태를 0.1초마다 확인합니다.
# '눌리는 순간'(이전에는 안 눌림 → 지금 눌림)만 반응해, 키를 누르고 있어도 한 번만 실행됩니다.
$hotkeyTimer = New-Object System.Windows.Forms.Timer
$hotkeyTimer.Interval = 100
$script:f9WasDown = $false
$script:f10WasDown = $false
$hotkeyTimer.Add_Tick({
    $f9Down = ([Win32.HotkeyPoll]::GetAsyncKeyState(0x78) -band 0x8000) -ne 0   # F9
    $f10Down = ([Win32.HotkeyPoll]::GetAsyncKeyState(0x79) -band 0x8000) -ne 0  # F10
    if ($f9Down -and -not $script:f9WasDown) {
      if ($script:running) {
        # 실행 중 F9 = 안전 중지 버튼과 동일 (예약 상태에서 다시 누르면 예약 취소 - 버튼 토글 그대로)
        Add-GuiLog '[단축키] F9 - 안전 중지'
        $btnSafeStop.PerformClick()
      } else {
        Add-GuiLog '[단축키] F9 - 시작'
        $btnStart.PerformClick()
      }
    }
    if ($f10Down -and -not $script:f10WasDown) {
      if ($script:running) {
        Add-GuiLog '[단축키] F10 - 즉시 중지'
        $btnKill.PerformClick()
      }
    }
    $script:f9WasDown = $f9Down
    $script:f10WasDown = $f10Down
  })

$script:uiReady = $true
Add-GuiLog '컨트롤 패널이 준비됐습니다. [시작]을 누르면 반복을 시작합니다. (단축키: F9 시작/안전 중지, F10 즉시 중지 - 게임 화면에서도 동작)'
if ($script:configMigrated) {
  Add-GuiLog '[안내] 업데이트 감지: 설정을 새 버전 형식으로 이전했습니다 (사용자 설정은 유지, 화면 좌표는 최신으로 갱신)'
}
$timer.Start()
$hotkeyTimer.Start()
# ===== 꿀비노기 허니 테마 (밝은 크림 + 꿀색) =====
# 모든 컨트롤 생성이 끝난 뒤 한 번에 입힙니다 (컨트롤 생성/로직 코드는 손대지 않음).
# 색 철학: 따뜻한 크림 배경 + 꿀색 강조 + 갈색 글자. 로그만 콘솔풍으로 어둡게.
# 실행 중 색을 바꾸는 곳은 상태 라벨뿐이며(초록/빨강/파랑/주황) 밝은 배경에서 모두 잘 보입니다.
$script:themeBack     = [System.Drawing.Color]::FromArgb(253, 248, 238)  # 창 배경 (크림)
$script:themeControl  = [System.Drawing.Color]::FromArgb(255, 253, 247)  # 일반 버튼 (밝은 크림)
$script:themeInput    = [System.Drawing.Color]::FromArgb(255, 255, 255)  # 입력 배경 (흰색)
$script:themeLogBack  = [System.Drawing.Color]::FromArgb(40, 34, 24)     # 로그 배경 (진한 갈색 콘솔풍)
$script:themeText     = [System.Drawing.Color]::FromArgb(66, 50, 22)     # 기본 글자 (진한 갈색)
$script:themeMuted    = [System.Drawing.Color]::FromArgb(158, 138, 104)  # 흐린 글자
$script:themeBorder   = [System.Drawing.Color]::FromArgb(226, 205, 160)  # 버튼 테두리 (연한 꿀색)
$script:themeTitle    = [System.Drawing.Color]::FromArgb(191, 128, 7)    # 섹션 제목 (꿀 갈색)
$script:themeHoney    = [System.Drawing.Color]::FromArgb(247, 181, 0)    # 꿀색 (강조)
$script:themeHoneyInk = [System.Drawing.Color]::FromArgb(66, 45, 0)      # 꿀색 위 글자
$script:themeDanger   = [System.Drawing.Color]::FromArgb(222, 105, 92)   # 위험(중지)

function Apply-HoneyTheme {
  param([System.Windows.Forms.Control]$Root)
  foreach ($ctl in @($Root.Controls)) {
    switch ($ctl.GetType().Name) {
      'Button' {
        $ctl.FlatStyle = 'Flat'
        $ctl.FlatAppearance.BorderColor = $script:themeBorder
        $ctl.FlatAppearance.BorderSize = 1
        $ctl.BackColor = $script:themeControl
        $ctl.ForeColor = $script:themeText
      }
      'GroupBox'    { $ctl.ForeColor = $script:themeTitle; $ctl.BackColor = $script:themeBack }
      'Label'       { $ctl.ForeColor = $script:themeText }
      'CheckBox'    { $ctl.ForeColor = $script:themeText }
      'RadioButton' { $ctl.ForeColor = $script:themeText }
      'Panel'       { $ctl.BackColor = $script:themeBack }
      'NumericUpDown' { $ctl.BackColor = $script:themeInput; $ctl.ForeColor = $script:themeText }
      'ComboBox'    { $ctl.BackColor = $script:themeInput; $ctl.ForeColor = $script:themeText }
      'RichTextBox' { $ctl.BackColor = $script:themeLogBack; $ctl.BorderStyle = 'None' }
    }
    if ($ctl.Controls.Count -gt 0) { Apply-HoneyTheme -Root $ctl }
  }
}

$form.BackColor = $script:themeBack
Apply-HoneyTheme -Root $form
# 강조색 지정 (일괄 적용 뒤 개별 덮어쓰기)
$btnStart.BackColor = $script:themeHoney
$btnStart.ForeColor = $script:themeHoneyInk
$btnStart.FlatAppearance.BorderSize = 0
$btnKill.BackColor = $script:themeDanger
$btnKill.ForeColor = [System.Drawing.Color]::White
$btnKill.FlatAppearance.BorderSize = 0
$btnSafeStop.BackColor = [System.Drawing.Color]::FromArgb(250, 240, 218)
$btnClearHelp.BackColor = $script:themeHoney
$btnClearHelp.ForeColor = $script:themeHoneyInk
$lblStatus.ForeColor = $script:themeTitle

[void]$form.ShowDialog()
$hotkeyTimer.Stop()
$timer.Stop()
