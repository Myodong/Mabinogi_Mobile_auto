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
$appVersion = '1.1.1'

$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot 'config.json'
$workerScript = Join-Path $scriptRoot 'mabinogi_run_once.ps1'
$workerLog = Join-Path $scriptRoot 'Log\mabinogi_run_once.log'
$workerRecoveryLog = Join-Path $scriptRoot 'Log\mabinogi_run_once.recovery.log'
# 안전 중지 신호 파일: GUI가 만들면 워커가 '던전 밖(HUD) 확인' 시점에서 회차를 조기 종료합니다.
$safeStopFlag = Join-Path $scriptRoot 'Log\safe_stop.flag'
# 커스텀 반복 완료 마커: 던전/어비스를 별도 파일로 두어 한쪽 모드로 먼저 시작해도 다른 쪽의
# 미완료 복구 근거가 지워지지 않게 합니다. 워커가 클리어 확정(결과 화면 도달) 시점에 현재
# 항목의 소유자 정보(리스트 지문/lap/index/항목 토큰)를 기록하고 코드 0에서 한 번만 전진합니다.
$customDungeonMarkerFile = Join-Path $scriptRoot 'Log\custom_done.marker' # 기존 던전 마커 경로 호환
$customAbyssMarkerFile = Join-Path $scriptRoot 'Log\abyss_custom_done.marker'
$customMarkerFile = $customDungeonMarkerFile
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

function Write-Utf8FileAtomic {
  param([string]$Path, [string]$Text)

  # 완성본을 같은 폴더의 임시 파일에 먼저 닫아 쓴 뒤 File.Replace 로 교체합니다.
  # 기존 파일은 교체 성공 전까지 그대로 남으므로 쓰기 중 종료/동시 읽기에도 부분 JSON이 보이지 않습니다.
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $dir = [System.IO.Path]::GetDirectoryName($fullPath)
  if (-not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
  $tempName = '.{0}.{1}.{2}.tmp' -f [System.IO.Path]::GetFileName($fullPath), $PID, ([guid]::NewGuid().ToString('N'))
  $tempPath = [System.IO.Path]::Combine($dir, $tempName)
  $backupPath = $tempPath + '.bak'
  try {
    $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllText($tempPath, $Text, $utf8Bom)
    if ([System.IO.File]::Exists($fullPath)) {
      [System.IO.File]::Replace($tempPath, $fullPath, $backupPath, $true)
    } else {
      [System.IO.File]::Move($tempPath, $fullPath)
    }
  } finally {
    if ([System.IO.File]::Exists($tempPath)) {
      [System.IO.File]::Delete($tempPath)
    }
    if ([System.IO.File]::Exists($backupPath)) {
      [System.IO.File]::Delete($backupPath)
    }
  }
}

function Save-Config {
  param($Config)
  $json = $Config | ConvertTo-Json -Depth 10
  # PS5.1 의 ConvertTo-Json 은 한글을 \uXXXX 로 바꾸므로 사람이 읽을 수 있게 복원합니다.
  $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
      param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
  # 교체 전 직렬화 결과 자체도 다시 파싱해, 유효하지 않은 JSON은 기존 config 를 건드리지 않습니다.
  [void]($json | ConvertFrom-Json -ErrorAction Stop)
  Write-Utf8FileAtomic -Path $configPath -Text $json
}

function Update-ConfigToLatest {
  # exe 업데이트 자동 이전: 사용자 config 의 좌표 버전(coordsVersion) 또는 설정 구조 버전
  # (configSchemaVersion)이 내장 최신 config(config.default.json)보다 낮으면 최신 config 를 기반으로
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
    $defSchema = 0; if ($def.PSObject.Properties['configSchemaVersion']) { $defSchema = [int]$def.configSchemaVersion }
    $usrSchema = 0; if ($usr.PSObject.Properties['configSchemaVersion']) { $usrSchema = [int]$usr.configSchemaVersion }
    if ($usrVer -ge $defVer -and $usrSchema -ge $defSchema) { return $false }

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
    foreach ($sect in @('normalDungeon', 'huntingGround', 'timeoutsSeconds', 'focus', 'repeat', 'diagnostics', 'window', 'rdp', 'ui', 'customRepeat', 'abyssCustomRepeat')) {
      if ($usr.PSObject.Properties[$sect] -and $def.PSObject.Properties[$sect]) {
        foreach ($prop in $usr.$sect.PSObject.Properties) {
          if ($prop.Name -like '_*') { continue }
          if ($def.$sect.PSObject.Properties[$prop.Name]) { $def.$sect.($prop.Name) = $prop.Value }
        }
      }
    }
    # 2-1) 커스텀 반복 특례: 리스트/설정은 위 루프로 이전하되 '진행 기록만' 초기화합니다.
    #      업데이트로 좌표/판정이 바뀌었을 수 있어 이어가기보다 처음부터가 안전 (요청사항 확정 스펙).
    #      사용자에게는 시작 로그로 안내합니다 ($script:customProgressReset).
    if ($def.PSObject.Properties['customRepeat']) {
      $hadCustomProgress = $false
      try {
        if ($usr.PSObject.Properties['customRepeat'] -and $usr.customRepeat -and
            $usr.customRepeat.PSObject.Properties['progress'] -and $usr.customRepeat.progress) {
          $hadCustomProgress = $true
        }
      } catch { }
      if ($def.customRepeat.PSObject.Properties['progress']) { $def.customRepeat.progress = $null }
      else { $def.customRepeat | Add-Member -NotePropertyName 'progress' -NotePropertyValue $null }
      $script:customProgressReset = $hadCustomProgress
    }
    if ($def.PSObject.Properties['abyssCustomRepeat']) {
      $hadAbyssCustomProgress = $false
      try {
        if ($usr.PSObject.Properties['abyssCustomRepeat'] -and $usr.abyssCustomRepeat -and
            $usr.abyssCustomRepeat.PSObject.Properties['progress'] -and $usr.abyssCustomRepeat.progress) {
          $hadAbyssCustomProgress = $true
        }
      } catch { }
      if ($def.abyssCustomRepeat.PSObject.Properties['progress']) { $def.abyssCustomRepeat.progress = $null }
      else { $def.abyssCustomRepeat | Add-Member -NotePropertyName 'progress' -NotePropertyValue $null }
      $script:customProgressReset = ($script:customProgressReset -or $hadAbyssCustomProgress)
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
function Read-NewLogLines {
  param([string]$Path, [ref]$Offset)
  if (-not (Test-Path -LiteralPath $Path)) {
    $Offset.Value = [long]0
    return @()
  }
  # 마지막으로 끝까지 기록된 줄의 다음 바이트부터만 읽습니다. LF(0x0A)는 UTF-8 다중 바이트
  # 안에 나타나지 않으므로 마지막 LF까지만 디코딩하고, 쓰는 중인 마지막 줄은 다음 호출에 남깁니다.
  # 파일이 회차 시작 때 삭제/재생성되어 짧아지면 오프셋을 0으로 되돌립니다.
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($fs.Length -lt [long]$Offset.Value) { $Offset.Value = [long]0 }
    $available = $fs.Length - [long]$Offset.Value
    if ($available -le 0) { return @() }
    if ($available -gt [int]::MaxValue) { throw '로그 증분 읽기 크기가 허용 범위를 넘었습니다.' }
    [void]$fs.Seek([long]$Offset.Value, [System.IO.SeekOrigin]::Begin)
    $bytes = New-Object byte[] ([int]$available)
    $read = 0
    while ($read -lt $bytes.Length) {
      $count = $fs.Read($bytes, $read, ($bytes.Length - $read))
      if ($count -le 0) { break }
      $read += $count
    }
    $lastLf = -1
    for ($i = $read - 1; $i -ge 0; $i--) {
      if ($bytes[$i] -eq 10) { $lastLf = $i; break }
    }
    if ($lastLf -lt 0) { return @() }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, ($lastLf + 1))
    $Offset.Value = [long]$Offset.Value + $lastLf + 1
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return @($text -split "`r?`n" | Where-Object { $_ })
  } catch { return $null }
  finally {
    if ($fs) { $fs.Dispose() }
  }
}

function Convert-WorkerLogLineForGui {
  param(
    [AllowEmptyString()][string]$Line,
    [bool]$CustomActive
  )

  # 진단·세부 동작은 원본 워커 로그에 그대로 보존하고, 컨트롤 패널에는 사용자가 진행 상황을
  # 판단하는 데 필요한 요약과 경고만 표시합니다.
  if ($Line -match '\[설정\]|\[준비\]\s*게임 확인:\s*PID|^\[\d{4}-\d{2}-\d{2}\]\s*자동화 로그\s*\(시작') {
    return $null
  }
  # 정상 워커 로그는 항상 시각으로 시작합니다. 드물게 파일 교체 경계에서 숫자 하나만 GUI에
  # 들어온 사례가 있어, 의미 없는 숫자 단독 줄은 화면에서만 버립니다(원본 로그는 변경하지 않음).
  if ($Line -match '^\s*\d+\s*$') { return $null }

  # 정상 적용 성공은 시작 요약과 최종 검증 로그로 충분합니다. 실패/경고는 이 패턴에 걸리지 않아
  # 그대로 표시됩니다.
  if ($Line -match "\[던전\]\s*'우연한 만남'\s*토글\s*(켬|켜짐 확인)" -or
      $Line -match '\[던전\].*난이도.*(재?클릭|추가 클릭 생략)' -or
      $Line -match '\[던전\]\s*(은동전\(소탕\)|더블 루팅)\s*=' -or
      $Line -match '\[던전\]\s*입장하기 클릭') {
    return $null
  }

  # 클리어 과정의 세부 단계는 파일에 남기고 GUI에서는 성공 요약 두 줄로 통합합니다.
  $timePrefix = ''
  if ($Line -match '^(\d{2}:\d{2}:\d{2}\s+)') { $timePrefix = $Matches[1] }
  if ($Line -match '\[던전\]\s*(던전 클리어 - 화면 터치|클리어 화면을 이미 지나친 상태)') { return "${timePrefix}[던전] 클리어 완료" }
  if ($Line -match '\[던전\]\s*결과 화면 확인') { return "${timePrefix}[던전] 결과 화면 확인" }
  if ($Line -match '\[던전\]\s*던전 클리어 화면 감지 대기 시작|\[던전\]\s*클리어 문구\(화면을 터치\) 감지|\[던전\]\s*결과 화면 감지 \(클리어 화면이 이미 지나감\)|\[던전\]\s*결과 화면 대기') {
    return $null
  }

  if ($CustomActive -and
      ($Line -match '\[커스텀\]\s*완료 마커 기록' -or
       $Line -match '\[던전\]\s*다시 하기 → 옵션 화면 복귀 - 회차 완료' -or
       $Line -match '\[커스텀\]\s*다음 층 화면 전환 확인 - 회차 완료' -or
       $Line -match '\[커스텀\].*완료 항목 마무리 복구\s*-' -or
       $Line -match '\[커스텀\]\s*마무리 목표 화면이')) {
    return $null
  }

  return $Line
}

# ----- 상태 변수 -----
$script:worker = $null
$script:running = $false
$script:stopRequested = $false
$script:completedCycles = 0
$script:targetCycles = 0      # 0 = 무한
$script:targetTime = $null    # 시간 지정 모드의 목표 시각 (null = 사용 안 함)
$script:logOffset = [long]0
$script:recoveryLogOffset = [long]0
$script:uiReady = $false      # 초기 로딩 중 설정 저장이 일어나지 않게 하는 플래그
$script:preparedStreak = 0    # 연속 '준비 실행'(코드 10) 횟수 - 화면 오판으로 인한 무한 준비 루프 방지 (컨트롤러와 동일)
# --- 커스텀 반복(던전/어비스 리스트 모드) 실행 컨텍스트 ---
$script:customActive = $false        # 이번 실행이 커스텀 반복 모드인지 (시작 시 확정 - 실행 중 라디오 변경 영향 차단)
$script:customConfigSection = 'customRepeat' # 실행 중 진행 기록을 읽고 쓸 config 섹션
$script:customErrorStreak = 0        # 같은 항목 연속 오류(코드 1) 횟수 - 2회까지 자동 재시작, 초과 시 정지
$script:customPrevItem = ''          # 직전 '완료' 항목 토큰 (HONEYNOGI_CUSTOM_PREV 용 - 빈 값이면 선택 화면 절차)
$script:customRestart = $false       # 다음 회차가 '오류 후 자동 재시작'인지 (복구 화면 판을 완료로 계상하는 플래그)
$script:customRecoveryPending = $false # 완료 마커가 있는 코드 1 뒤, 같은 항목의 결과 화면 마무리만 복구 중인지
$script:customMarkerIgnore = $false  # 실행 직전 이전 마커 삭제 실패 시 이번 회차는 마커 무시 (오계상 방지)
$script:crLoading = $false           # 커스텀 리스트뷰를 프로그램적으로 조작 중일 때 저장 이벤트 억제 가드
$script:crSwitching = $false         # 카테고리 전환에 의한 커스텀 라디오 폴백/복원 중 가드 (enabled 보존)
$script:customEnabledWish = $false   # 커스텀 반복 '선택 의도' - 던전 외 카테고리에서 라디오가 풀려도 보존 (config enabled 와 동기)
$script:customProgressReset = $false # 업데이트 이전(Update-ConfigToLatest)에서 진행 기록을 초기화했는지 (시작 로그 안내용)
$script:acrLockUpdating = $false     # 어비스 커스텀 방식·매칭 잠금 적용 중 재진입 가드 (라디오 Checked 변경 → 패널 갱신 → 재호출 방지)
$script:acrLockOn = $false           # 어비스 방식·매칭이 리스트 값으로 잠겨 있는지 (비활성 라디오 툴팁 판정용)
$script:acrTipShownFor = $null       # 현재 툴팁을 띄워 둔 잠긴 라디오 (같은 컨트롤에서 반복 호출 → 깜박임 방지)

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

# 4번째 라디오('커스텀 반복')를 한 줄에 넣기 위해 기존 컨트롤들의 가로 배치를 압축했습니다
# (화면 좌표가 아닌 GUI 배치라 coordsVersion 과 무관)
$rbInfinite = New-Object System.Windows.Forms.RadioButton
$rbInfinite.Text = '무한 반복'
$rbInfinite.Location = New-Object System.Drawing.Point(15, 20)
$rbInfinite.Size = New-Object System.Drawing.Size(80, 22)
$rbInfinite.Checked = $true
$grpRepeat.Controls.Add($rbInfinite)

$rbCount = New-Object System.Windows.Forms.RadioButton
$rbCount.Text = '횟수 지정:'
$rbCount.Location = New-Object System.Drawing.Point(100, 20)
$rbCount.Size = New-Object System.Drawing.Size(80, 22)
$grpRepeat.Controls.Add($rbCount)

$numCount = New-Object System.Windows.Forms.NumericUpDown
$numCount.Location = New-Object System.Drawing.Point(180, 18)
$numCount.Size = New-Object System.Drawing.Size(55, 24)
$numCount.Minimum = 1
$numCount.Maximum = 9999
$numCount.Value = 2
$grpRepeat.Controls.Add($numCount)

$rbTime = New-Object System.Windows.Forms.RadioButton
$rbTime.Text = '시간 지정:'
$rbTime.Location = New-Object System.Drawing.Point(240, 20)
$rbTime.Size = New-Object System.Drawing.Size(80, 22)
$grpRepeat.Controls.Add($rbTime)

$dtpUntil = New-Object System.Windows.Forms.DateTimePicker
$dtpUntil.Format = 'Custom'
$dtpUntil.CustomFormat = 'HH:mm'
$dtpUntil.ShowUpDown = $true
$dtpUntil.Location = New-Object System.Drawing.Point(320, 18)
$dtpUntil.Size = New-Object System.Drawing.Size(66, 24)
$grpRepeat.Controls.Add($dtpUntil)

# 커스텀 반복 (던전/어비스 실행 지원, 사냥터 미지원).
# 선택하면 상단 횟수/시간 입력은 비활성 - 반복 방식은 콘텐츠별 리스트의 '리스트 반복'이 담당합니다.
# 선택 여부는 config(customRepeat.enabled)에 영속화됩니다 (재시작 후 옛 단일 설정 오작동 방지).
$rbCustomRepeat = New-Object System.Windows.Forms.RadioButton
$rbCustomRepeat.Text = '커스텀 반복'
$rbCustomRepeat.Location = New-Object System.Drawing.Point(420, 20)
$rbCustomRepeat.Size = New-Object System.Drawing.Size(125, 22)
$rbCustomRepeat.Enabled = $false   # 던전/어비스 카테고리에서 활성 (updateCategoryPanels 가 제어)
$grpRepeat.Controls.Add($rbCustomRepeat)

$rbCustomRepeat.Add_CheckedChanged({
    # 커스텀 선택 시 상단 횟수/시간 입력 비활성 (택일 관계 - 반복은 하단 '리스트 반복'이 담당)
    $numCount.Enabled = -not $rbCustomRepeat.Checked
    $dtpUntil.Enabled = -not $rbCustomRepeat.Checked
    if (-not $script:crSwitching) {
      # 카테고리 전환에 의한 표시상 폴백/복원(crSwitching)이 아닌 '실제 선택 변경'만 의도로 기억/저장
      $script:customEnabledWish = [bool]$rbCustomRepeat.Checked
      if ($script:uiReady -and -not $script:crLoading) { Save-CustomRepeatToConfig }
    }
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })

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

# 중지 버튼 2개는 평소 숨겨져 있다가 실행 중에만 시작 버튼 자리부터 나타납니다
# (대기 중 중지 오클릭 / 실행 중 시작 오클릭 방지 - Set-UiRunning 이 전환)
$btnSafeStop = New-Object System.Windows.Forms.Button
$btnSafeStop.Text = ("안전 중지(F9)" + [Environment]::NewLine + "(회차 완료 후)")
$btnSafeStop.Location = New-Object System.Drawing.Point(15, 104)
$btnSafeStop.Size = New-Object System.Drawing.Size(210, 38)
$btnSafeStop.Enabled = $false
$btnSafeStop.Visible = $false
$form.Controls.Add($btnSafeStop)

$btnKill = New-Object System.Windows.Forms.Button
$btnKill.Text = '즉시 중지(F10)'
$btnKill.Location = New-Object System.Drawing.Point(231, 104)
$btnKill.Size = New-Object System.Drawing.Size(150, 38)
$btnKill.Enabled = $false
$btnKill.Visible = $false
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
      " 3) [시작] 버튼을 클릭 후 마우스를 잠시 움직이지 마세요.`n`n" +
      "[커스텀 반복]`n" +
      " - 반복에서 '커스텀 반복'을 선택하면 리스트에 추가한 항목(난이도+구역+은동전)을`n" +
      "   위에서부터 순서대로 1판씩 실행합니다 (같은 항목을 여러 번 추가하면 그만큼 반복).`n" +
      " - 시작 시 열어 둔 던전 하나에서만 동작합니다 (리스트에 던전 구분 없음).`n" +
      " - 1차 버전은 매칭 설정과 무관하게 '우연한 만남'으로 진행합니다.`n" +
      " - 은동전 항목은 실제로 은동전이 소모되니 잔량을 확인해 주세요."
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
$lblNdStage.Text = '구역:'
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

# 비커스텀 던전도 커스텀 항목과 같은 2단계 소진 대응 라디오를 사용합니다.
# 저장 키(continueWithoutCoin/continueSweepOnly)는 구버전 config 호환을 위해 그대로 유지합니다.
$pnlNdExhaust = New-Object System.Windows.Forms.Panel
$pnlNdExhaust.Location = New-Object System.Drawing.Point(15, 116)
$pnlNdExhaust.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdExhaust.Visible = $false
$grpContentDetail.Controls.Add($pnlNdExhaust)

$lblNdExhaust = New-Object System.Windows.Forms.Label
$lblNdExhaust.Text = '동전 소진 시(잔량 10 미만):'
$lblNdExhaust.Location = New-Object System.Drawing.Point(0, 5)
$lblNdExhaust.Size = New-Object System.Drawing.Size(175, 20)
$pnlNdExhaust.Controls.Add($lblNdExhaust)

$rbNdExhaustStop = New-Object System.Windows.Forms.RadioButton
$rbNdExhaustStop.Text = '멈춤'
$rbNdExhaustStop.Location = New-Object System.Drawing.Point(180, 2)
$rbNdExhaustStop.Size = New-Object System.Drawing.Size(60, 22)
$rbNdExhaustStop.Checked = $true
$pnlNdExhaust.Controls.Add($rbNdExhaustStop)

$rbNdExhaustGo = New-Object System.Windows.Forms.RadioButton
$rbNdExhaustGo.Text = '미사용으로 진행'
$rbNdExhaustGo.Location = New-Object System.Drawing.Point(245, 2)
$rbNdExhaustGo.Size = New-Object System.Drawing.Size(135, 22)
$pnlNdExhaust.Controls.Add($rbNdExhaustGo)

$pnlNdNoDouble = New-Object System.Windows.Forms.Panel
$pnlNdNoDouble.Location = New-Object System.Drawing.Point(15, 142)
$pnlNdNoDouble.Size = New-Object System.Drawing.Size(524, 26)
$pnlNdNoDouble.Visible = $false
$grpContentDetail.Controls.Add($pnlNdNoDouble)

$lblNdNoDouble = New-Object System.Windows.Forms.Label
$lblNdNoDouble.Text = '더블 루팅 불가 시(잔량 10~19):'
$lblNdNoDouble.Location = New-Object System.Drawing.Point(0, 5)
$lblNdNoDouble.Size = New-Object System.Drawing.Size(195, 20)
$pnlNdNoDouble.Controls.Add($lblNdNoDouble)

$rbNdNoDoubleStop = New-Object System.Windows.Forms.RadioButton
$rbNdNoDoubleStop.Text = '멈춤'
$rbNdNoDoubleStop.Location = New-Object System.Drawing.Point(200, 2)
$rbNdNoDoubleStop.Size = New-Object System.Drawing.Size(60, 22)
$rbNdNoDoubleStop.Checked = $true
$pnlNdNoDouble.Controls.Add($rbNdNoDoubleStop)

$rbNdNoDoubleSweep = New-Object System.Windows.Forms.RadioButton
$rbNdNoDoubleSweep.Text = '소탕만 진행'
$rbNdNoDoubleSweep.Location = New-Object System.Drawing.Point(265, 2)
$rbNdNoDoubleSweep.Size = New-Object System.Drawing.Size(110, 22)
$pnlNdNoDouble.Controls.Add($rbNdNoDoubleSweep)

# 더블 루팅을 해제하면 해당하지 않는 두 번째 단계는 기본값(멈춤)으로 되돌립니다.
$chkNdDoubleLoot.Add_CheckedChanged({
    if (-not $chkNdDoubleLoot.Checked) { $rbNdNoDoubleStop.Checked = $true }
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })

# 은동전 사용을 해제하면 숨겨지는 소진 대응도 기본값(멈춤)으로 되돌립니다.
$chkNdCoin.Add_CheckedChanged({
    $chkNdDoubleLoot.Visible = $chkNdCoin.Checked
    if (-not $chkNdCoin.Checked) {
      $chkNdDoubleLoot.Checked = $false
      $rbNdExhaustStop.Checked = $true
      $rbNdNoDoubleStop.Checked = $true
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

# ============================================================
#  '던전 + 커스텀 반복' 전용 리스트 빌더 (반복 그룹에서 '커스텀 반복'을 고르면 단일 모드
#  줄들 대신 아래 패널들이 표시됩니다. 리스트 편집은 즉시 config(customRepeat)에 저장)
# ============================================================
# 입력 줄: 난이도 + 스테이지 + 은동전 + 더블 루팅(은동전 체크 시만 표시).
# [추가] 버튼은 리스트 옆 버튼 열 최상단에 있습니다
$pnlCrInput = New-Object System.Windows.Forms.Panel
$pnlCrInput.Location = New-Object System.Drawing.Point(15, 20)
$pnlCrInput.Size = New-Object System.Drawing.Size(524, 26)
$pnlCrInput.Visible = $false
$grpContentDetail.Controls.Add($pnlCrInput)

$cboCrDifficulty = New-Object System.Windows.Forms.ComboBox
$cboCrDifficulty.Location = New-Object System.Drawing.Point(0, 1)
$cboCrDifficulty.Size = New-Object System.Drawing.Size(75, 24)
$cboCrDifficulty.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($crDifficultyName in @('일반', '어려움')) { [void]$cboCrDifficulty.Items.Add($crDifficultyName) }
$cboCrDifficulty.SelectedIndex = 0
$pnlCrInput.Controls.Add($cboCrDifficulty)

$cboCrStage = New-Object System.Windows.Forms.ComboBox
$cboCrStage.Location = New-Object System.Drawing.Point(85, 1)
$cboCrStage.Size = New-Object System.Drawing.Size(70, 24)
$cboCrStage.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($crChapter in 1..2) {
  foreach ($crStep in 1..3) { [void]$cboCrStage.Items.Add("$crChapter-$crStep") }
}
$cboCrStage.SelectedIndex = 0
$pnlCrInput.Controls.Add($cboCrStage)

$chkCrCoin = New-Object System.Windows.Forms.CheckBox
$chkCrCoin.Text = '은동전'
$chkCrCoin.Location = New-Object System.Drawing.Point(165, 2)
$chkCrCoin.Size = New-Object System.Drawing.Size(70, 22)
$pnlCrInput.Controls.Add($chkCrCoin)

$chkCrDouble = New-Object System.Windows.Forms.CheckBox
$chkCrDouble.Text = '더블 루팅'
$chkCrDouble.Location = New-Object System.Drawing.Point(240, 2)
$chkCrDouble.Size = New-Object System.Drawing.Size(90, 22)
$chkCrDouble.Visible = $false   # 은동전 체크 시에만 표시 (단일 모드 chkNdCoin 과 동일한 동작)
$pnlCrInput.Controls.Add($chkCrDouble)

# 입력 줄 아래 라디오 줄 2개: '다음에 [추가]할 항목'의 소진/더블 불가 대응 속성입니다.
# 즉시 저장 대상이 아니라 [추가]로 리스트에 들어갈 때 항목별 속성으로 기록됩니다.
# 기본값 = 멈춤. 소진 줄은 은동전 체크 시, 더블 불가 줄은 더블 루팅 체크 시에만 표시
# (표시/배치는 updateCategoryPanels 가 제어 - 소진 줄이 위, 더블 불가 줄이 아래)
$pnlCrExhaust = New-Object System.Windows.Forms.Panel
$pnlCrExhaust.Location = New-Object System.Drawing.Point(15, 50)
$pnlCrExhaust.Size = New-Object System.Drawing.Size(524, 26)
$pnlCrExhaust.Visible = $false
$grpContentDetail.Controls.Add($pnlCrExhaust)

$lblCrExhaust = New-Object System.Windows.Forms.Label
$lblCrExhaust.Text = '동전 소진 시(잔량 10 미만):'
$lblCrExhaust.Location = New-Object System.Drawing.Point(0, 5)
# 폭 195 = 아래 '더블 루팅 불가 시' 라벨과 동일 - 두 줄의 라디오 시작 위치를 세로로 맞춥니다
$lblCrExhaust.Size = New-Object System.Drawing.Size(195, 20)
$pnlCrExhaust.Controls.Add($lblCrExhaust)

$rbCrExhaustStop = New-Object System.Windows.Forms.RadioButton
$rbCrExhaustStop.Text = '멈춤'
$rbCrExhaustStop.Location = New-Object System.Drawing.Point(200, 2)
$rbCrExhaustStop.Size = New-Object System.Drawing.Size(60, 22)
$rbCrExhaustStop.Checked = $true
$pnlCrExhaust.Controls.Add($rbCrExhaustStop)

$rbCrExhaustGo = New-Object System.Windows.Forms.RadioButton
$rbCrExhaustGo.Text = '미사용으로 진행'
$rbCrExhaustGo.Location = New-Object System.Drawing.Point(265, 2)
$rbCrExhaustGo.Size = New-Object System.Drawing.Size(135, 22)
$pnlCrExhaust.Controls.Add($rbCrExhaustGo)

$pnlCrNoDouble = New-Object System.Windows.Forms.Panel
$pnlCrNoDouble.Location = New-Object System.Drawing.Point(15, 76)
$pnlCrNoDouble.Size = New-Object System.Drawing.Size(524, 26)
$pnlCrNoDouble.Visible = $false
$grpContentDetail.Controls.Add($pnlCrNoDouble)

$lblCrNoDouble = New-Object System.Windows.Forms.Label
$lblCrNoDouble.Text = '더블 루팅 불가 시(잔량 10~19):'
$lblCrNoDouble.Location = New-Object System.Drawing.Point(0, 5)
$lblCrNoDouble.Size = New-Object System.Drawing.Size(195, 20)
$pnlCrNoDouble.Controls.Add($lblCrNoDouble)

$rbCrNoDoubleStop = New-Object System.Windows.Forms.RadioButton
$rbCrNoDoubleStop.Text = '멈춤'
$rbCrNoDoubleStop.Location = New-Object System.Drawing.Point(200, 2)
$rbCrNoDoubleStop.Size = New-Object System.Drawing.Size(60, 22)
$rbCrNoDoubleStop.Checked = $true
$pnlCrNoDouble.Controls.Add($rbCrNoDoubleStop)

$rbCrNoDoubleSweep = New-Object System.Windows.Forms.RadioButton
$rbCrNoDoubleSweep.Text = '소탕만 진행'
$rbCrNoDoubleSweep.Location = New-Object System.Drawing.Point(265, 2)
$rbCrNoDoubleSweep.Size = New-Object System.Drawing.Size(110, 22)
$pnlCrNoDouble.Controls.Add($rbCrNoDoubleSweep)

# 입력 줄의 은동전 체크: 더블 루팅 표시/해제 + 라디오 줄 표시 변경 (입력 줄 자체는 저장
# 대상이 아니라 저장 없음 - 항목은 [추가]를 눌러 리스트에 들어갈 때만 config 에 반영됩니다).
# 줄 표시가 바뀌면 리스트/하단 줄 위치와 그룹 높이를 updateCategoryPanels 로 재배치합니다
$chkCrCoin.Add_CheckedChanged({
    $chkCrDouble.Visible = $chkCrCoin.Checked
    if (-not $chkCrCoin.Checked) { $chkCrDouble.Checked = $false }
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })
$chkCrDouble.Add_CheckedChanged({
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })

# 리스트 (표 형태): 체크 / # / 난이도 / 구역 / 은동전(판당 소모량 - 더블 루팅 20개/소탕만 10개/미사용 0개)
#                 / 소진 시(진행·멈춤·—) / 더블 불가 시(소탕만·멈춤·—) - 뒤 2열은 항목별 소진 대응 속성
$lvCrList = New-Object System.Windows.Forms.ListView
$lvCrList.Location = New-Object System.Drawing.Point(15, 52)
$lvCrList.Size = New-Object System.Drawing.Size(420, 150)
$lvCrList.View = [System.Windows.Forms.View]::Details
$lvCrList.GridLines = $true
$lvCrList.CheckBoxes = $true
$lvCrList.FullRowSelect = $true
$lvCrList.MultiSelect = $false
$lvCrList.HideSelection = $false
$lvCrList.Visible = $false
[void]$lvCrList.Columns.Add('', 28)
[void]$lvCrList.Columns.Add('#', 32)
[void]$lvCrList.Columns.Add('난이도', 62)
[void]$lvCrList.Columns.Add('구역', 52)
[void]$lvCrList.Columns.Add('은동전', 62)
[void]$lvCrList.Columns.Add('소진 시', 86)
[void]$lvCrList.Columns.Add('더블 불가 시', 96)
$grpContentDetail.Controls.Add($lvCrList)

# 0번(체크) 열 머리글 클릭 = 전체 선택/해제. WinForms ListView 에는 실제 머리글 체크박스가
# 없어 열 클릭으로 구현합니다 (요청사항의 '머리글 체크박스 칸 클릭' 스펙 충족).
$lvCrList.Add_ColumnClick({
    param($clickSender, $clickArgs)
    if ($clickArgs.Column -ne 0) { return }
    if ($lvCrList.Items.Count -eq 0) { return }
    $allChecked = $true
    foreach ($crRow in $lvCrList.Items) { if (-not $crRow.Checked) { $allChecked = $false; break } }
    $newState = -not $allChecked
    $prevLoading = $script:crLoading
    $script:crLoading = $true
    try { foreach ($crRow in $lvCrList.Items) { $crRow.Checked = $newState } }
    finally { $script:crLoading = $prevLoading }
  })

# 리스트 옆 버튼 열: [추가] [삭제] [↑] [↓] 순서 (추가 = 입력 줄+라디오 줄의 현재 상태를
# 항목으로 리스트에 넣음 / 삭제 = 체크 항목 일괄 / ↑↓ = 선택한 1줄 이동).
# Top 값은 라디오 줄 표시에 따라 updateCategoryPanels 가 리스트와 함께 재배치합니다
$btnCrAdd = New-Object System.Windows.Forms.Button
$btnCrAdd.Text = '추가'
$btnCrAdd.Location = New-Object System.Drawing.Point(445, 52)
$btnCrAdd.Size = New-Object System.Drawing.Size(94, 30)
$btnCrAdd.Visible = $false
$grpContentDetail.Controls.Add($btnCrAdd)

$btnCrDelete = New-Object System.Windows.Forms.Button
$btnCrDelete.Text = '삭제(체크)'
$btnCrDelete.Location = New-Object System.Drawing.Point(445, 88)
$btnCrDelete.Size = New-Object System.Drawing.Size(94, 30)
$btnCrDelete.Visible = $false
$grpContentDetail.Controls.Add($btnCrDelete)

$btnCrUp = New-Object System.Windows.Forms.Button
$btnCrUp.Text = '↑ 위로'
$btnCrUp.Location = New-Object System.Drawing.Point(445, 124)
$btnCrUp.Size = New-Object System.Drawing.Size(94, 30)
$btnCrUp.Visible = $false
$grpContentDetail.Controls.Add($btnCrUp)

$btnCrDown = New-Object System.Windows.Forms.Button
$btnCrDown.Text = '↓ 아래로'
$btnCrDown.Location = New-Object System.Drawing.Point(445, 160)
$btnCrDown.Size = New-Object System.Drawing.Size(94, 30)
$btnCrDown.Visible = $false
$grpContentDetail.Controls.Add($btnCrDown)

$btnCrAdd.Add_Click({
    $crDifficultyValue = [string]$cboCrDifficulty.SelectedItem
    $crStageValue = [string]$cboCrStage.SelectedItem
    if (-not $crDifficultyValue -or -not $crStageValue) { return }
    # 소진/더블 대응 정규화: coin=false 면 둘 다 false, double=false 면 noDoubleSweep=false.
    # double=true + 멈춤(noDoubleSweep=false)이면 소진 분기에 도달할 수 없어 exhaustContinue 도
    # false 로 저장합니다 (리스트 '—' 표기 ↔ Get-CustomItemsFromList 역해석 false 와 일치 -
    # 여기서 true 를 남기면 리스트 재저장 때 값이 바뀌어 지문 불일치로 진행 기록이 날아감)
    $crCoinValue = [bool]$chkCrCoin.Checked
    $crDoubleValue = [bool]($crCoinValue -and $chkCrDouble.Checked)
    $crNoDoubleValue = [bool]($crDoubleValue -and $rbCrNoDoubleSweep.Checked)
    $crExhaustValue = [bool]($crCoinValue -and $rbCrExhaustGo.Checked -and
      ((-not $crDoubleValue) -or $crNoDoubleValue))
    # 추가 차단 (2026-07-20 사용자 확정): 마지막 항목 → 새 항목 전환이 게임에서 불가능한
    # 조합(2층→1층 / 1-3 아닌 1층→2층)이면 추가하지 않고 팝업으로 안내합니다.
    # 이 팝업은 사용자가 [추가]를 누른 직후에만 뜰 수 있어 무인 운용을 막지 않음 -
    # 'GUI 팝업 금지' 규칙의 명시적 예외 (CLAUDE.md 참고. 실행 중엔 상세 설정이 비활성이라
    # 자동화 도중에는 발생 불가). ↑↓ 이동/삭제는 재배치 중간 상태가 일시적으로 위반일 수
    # 있어 차단하지 않고 경고 로그 + 시작 게이트로만 잡습니다.
    $crExistingItems = @(Get-CustomItemsFromList)
    if ($crExistingItems.Count -gt 0) {
      $crLastItem = $crExistingItems[$crExistingItems.Count - 1]
      $crNewItem = [pscustomobject]@{
        difficulty = $crDifficultyValue; stage = $crStageValue
        coin = $crCoinValue; doubleLoot = $crDoubleValue
        exhaustContinue = $crExhaustValue; noDoubleSweep = $crNoDoubleValue
      }
      # 마지막→새 항목 한 쌍만 검사 (count/1바퀴로 호출해 순환 검사는 제외 - 기존 위반과 무관하게
      # 이번 추가가 만드는 전환만 판정)
      $crPairIssues = @(Get-CustomTransitionIssues -Items @($crLastItem, $crNewItem) `
          -ListRepeat 'count' -ListRepeatCount 1)
      if ($crPairIssues.Count -gt 0) {
        $crBlockText = ("이 순서로는 추가할 수 없습니다.`n`n" +
          "마지막 항목 '{0}' 다음에 '{1}' 항목은 올 수 없습니다.`n{2}" -f `
            (Get-CustomItemLabel -Item $crLastItem), (Get-CustomItemLabel -Item $crNewItem), `
            [string]$crPairIssues[0].Reason)
        Add-GuiLog ('[안내] 추가 차단: {0} → {1} - {2}' -f `
            (Get-CustomItemLabel -Item $crLastItem), (Get-CustomItemLabel -Item $crNewItem), `
            [string]$crPairIssues[0].Reason)
        [System.Windows.Forms.MessageBox]::Show($crBlockText, '커스텀 반복 - 추가 불가',
          [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
      }
    }
    $prevLoading = $script:crLoading
    $script:crLoading = $true
    try {
      Add-CustomListRow -Difficulty $crDifficultyValue -Stage $crStageValue `
        -Coin $crCoinValue -DoubleLoot $crDoubleValue `
        -ExhaustContinue $crExhaustValue -NoDoubleSweep $crNoDoubleValue
      Update-CustomListNumbers
    } finally { $script:crLoading = $prevLoading }
    if ($script:uiReady) { Save-CustomRepeatToConfig }
    # 전환 규칙 사전 경고: 지금 리스트에 불가능한 층 전환이 있으면 알려만 줍니다 (추가 자체는
    # 허용 - 이후 항목 추가로 위반이 해소될 수 있음. 최종 차단은 시작 버튼 게이트가 같은
    # 함수(Get-CustomTransitionIssues)로 수행)
    $crAddRepeat = $(if ($rbCrCount.Checked) { 'count' } else { 'infinite' })
    $crAddIssues = @(Get-CustomTransitionIssues -Items @(Get-CustomItemsFromList) `
        -ListRepeat $crAddRepeat -ListRepeatCount ([int]$numCrLaps.Value))
    foreach ($crAddIssue in $crAddIssues) {
      $crAddWrapTag = $(if ([bool]$crAddIssue.Wrap) { ' [바퀴 순환: 마지막 → 첫 항목]' } else { '' })
      Add-GuiLog ('[경고] {0} → {1}{2}: {3} - 이대로는 시작할 수 없습니다 (순서 조정 또는 뒤에 항목을 더 추가해 해소해 주세요).' -f `
          $crAddIssue.From, $crAddIssue.To, $crAddWrapTag, $crAddIssue.Reason)
    }
  })

$btnCrDelete.Add_Click({
    $checkedRows = @()
    foreach ($crRow in $lvCrList.Items) { if ($crRow.Checked) { $checkedRows += $crRow } }
    if ($checkedRows.Count -eq 0) {
      Add-GuiLog '[안내] 삭제할 항목의 앞 체크박스를 켠 뒤 [삭제(체크)]를 눌러 주세요. (첫 열 머리글 클릭 = 전체 선택/해제)'
      return
    }
    $prevLoading = $script:crLoading
    $script:crLoading = $true
    try {
      foreach ($crRow in $checkedRows) { $lvCrList.Items.Remove($crRow) }
      Update-CustomListNumbers
    } finally { $script:crLoading = $prevLoading }
    if ($script:uiReady) { Save-CustomRepeatToConfig }
  })

$btnCrUp.Add_Click({ Move-CustomListRow -Delta (-1) })
$btnCrDown.Add_Click({ Move-CustomListRow -Delta 1 })

# 하단 줄: 리스트 반복 (무한 / 횟수 N바퀴 - '바퀴' 표기로 상단 '횟수 지정'과 구분) + 진행 초기화
# (소진 대응은 항목별 속성으로 옮겨 전역 소진 대응 줄(pnlCrFallback)은 폐지됐습니다)
$pnlCrRepeat = New-Object System.Windows.Forms.Panel
$pnlCrRepeat.Location = New-Object System.Drawing.Point(15, 238)
$pnlCrRepeat.Size = New-Object System.Drawing.Size(524, 28)
$pnlCrRepeat.Visible = $false
$grpContentDetail.Controls.Add($pnlCrRepeat)

$lblCrRepeat = New-Object System.Windows.Forms.Label
$lblCrRepeat.Text = '리스트 반복:'
$lblCrRepeat.Location = New-Object System.Drawing.Point(0, 5)
$lblCrRepeat.Size = New-Object System.Drawing.Size(80, 20)
$pnlCrRepeat.Controls.Add($lblCrRepeat)

$rbCrInfinite = New-Object System.Windows.Forms.RadioButton
$rbCrInfinite.Text = '무한'
$rbCrInfinite.Location = New-Object System.Drawing.Point(85, 2)
$rbCrInfinite.Size = New-Object System.Drawing.Size(55, 22)
$rbCrInfinite.Checked = $true
$pnlCrRepeat.Controls.Add($rbCrInfinite)

$rbCrCount = New-Object System.Windows.Forms.RadioButton
$rbCrCount.Text = '횟수:'
$rbCrCount.Location = New-Object System.Drawing.Point(145, 2)
$rbCrCount.Size = New-Object System.Drawing.Size(60, 22)
$pnlCrRepeat.Controls.Add($rbCrCount)

$numCrLaps = New-Object System.Windows.Forms.NumericUpDown
$numCrLaps.Location = New-Object System.Drawing.Point(205, 0)
$numCrLaps.Size = New-Object System.Drawing.Size(50, 24)
$numCrLaps.Minimum = 1
$numCrLaps.Maximum = 999
$numCrLaps.Value = 1
$numCrLaps.Enabled = $false   # '횟수' 라디오를 골랐을 때만 활성
$pnlCrRepeat.Controls.Add($numCrLaps)

$lblCrLaps = New-Object System.Windows.Forms.Label
$lblCrLaps.Text = '바퀴'
$lblCrLaps.Location = New-Object System.Drawing.Point(258, 5)
$lblCrLaps.Size = New-Object System.Drawing.Size(35, 20)
$pnlCrRepeat.Controls.Add($lblCrLaps)

# 리스트에 필요한 은동전 합계 표시 (합산 Get-CustomCoinTotalPerLap / 갱신 Update-CustomCoinTotalLabel)
$lblCrCoinTotal = New-Object System.Windows.Forms.Label
$lblCrCoinTotal.Text = '바퀴당 은동전 0개'
$lblCrCoinTotal.Location = New-Object System.Drawing.Point(293, 5)
$lblCrCoinTotal.Size = New-Object System.Drawing.Size(122, 20)
$lblCrCoinTotal.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblCrCoinTotal.ForeColor = [System.Drawing.Color]::SteelBlue
$pnlCrRepeat.Controls.Add($lblCrCoinTotal)

$btnCrReset = New-Object System.Windows.Forms.Button
$btnCrReset.Text = '진행 초기화'
$btnCrReset.Location = New-Object System.Drawing.Point(430, 0)
$btnCrReset.Size = New-Object System.Drawing.Size(94, 26)
$pnlCrRepeat.Controls.Add($btnCrReset)

# 커스텀 설정 변경 = 즉시 저장 (ui.logFontSize 즉시 저장 패턴. 로딩 중에는 가드로 억제)
# 라디오 전환은 상대 버튼 CheckedChanged 도 발화하므로 '횟수' 버튼 하나로 켬/끔 전환을 모두 잡습니다
$rbCrCount.Add_CheckedChanged({
    $numCrLaps.Enabled = $rbCrCount.Checked
    if ($script:uiReady -and -not $script:crLoading) { Save-CustomRepeatToConfig }
  })
$numCrLaps.Add_ValueChanged({ if ($script:uiReady -and -not $script:crLoading) { Save-CustomRepeatToConfig } })
$btnCrReset.Add_Click({
    Reset-CustomProgress -SectionName 'customRepeat' `
      -LogMessage '[안내] 커스텀 반복 진행 기록을 초기화했습니다 - 다음 시작은 리스트 처음(1바퀴째 1번)부터입니다.'
  })

# ============================================================
#  '어비스 + 커스텀 반복' 목록/설정 화면
#  던전 커스텀과 별도 목록을 사용하되 진행 기록·완료 마커·오류 재시도 계약은 공용입니다.
# ============================================================
$pnlAcrInput = New-Object System.Windows.Forms.Panel
$pnlAcrInput.Location = New-Object System.Drawing.Point(15, 20)
$pnlAcrInput.Size = New-Object System.Drawing.Size(524, 26)
$pnlAcrInput.Visible = $false
$grpContentDetail.Controls.Add($pnlAcrInput)

$rbAcrSolo = New-Object System.Windows.Forms.RadioButton
$rbAcrSolo.Text = '혼자하기'
$rbAcrSolo.Location = New-Object System.Drawing.Point(0, 2)
$rbAcrSolo.Size = New-Object System.Drawing.Size(82, 22)
$rbAcrSolo.Checked = $true
$pnlAcrInput.Controls.Add($rbAcrSolo)

$rbAcrParty = New-Object System.Windows.Forms.RadioButton
$rbAcrParty.Text = '함께하기'
$rbAcrParty.Location = New-Object System.Drawing.Point(85, 2)
$rbAcrParty.Size = New-Object System.Drawing.Size(86, 22)
$pnlAcrInput.Controls.Add($rbAcrParty)

$lblAcrDifficulty = New-Object System.Windows.Forms.Label
$lblAcrDifficulty.Text = '난이도:'
$lblAcrDifficulty.Location = New-Object System.Drawing.Point(175, 5)
$lblAcrDifficulty.Size = New-Object System.Drawing.Size(50, 20)
$pnlAcrInput.Controls.Add($lblAcrDifficulty)

$cboAcrDifficulty = New-Object System.Windows.Forms.ComboBox
$cboAcrDifficulty.Location = New-Object System.Drawing.Point(225, 1)
$cboAcrDifficulty.Size = New-Object System.Drawing.Size(96, 24)
$cboAcrDifficulty.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$pnlAcrInput.Controls.Add($cboAcrDifficulty)

$lblAcrDungeon = New-Object System.Windows.Forms.Label
$lblAcrDungeon.Text = '어비스:'
$lblAcrDungeon.Location = New-Object System.Drawing.Point(330, 5)
$lblAcrDungeon.Size = New-Object System.Drawing.Size(50, 20)
$pnlAcrInput.Controls.Add($lblAcrDungeon)

$cboAcrDungeon = New-Object System.Windows.Forms.ComboBox
$cboAcrDungeon.Location = New-Object System.Drawing.Point(380, 1)
$cboAcrDungeon.Size = New-Object System.Drawing.Size(144, 24)
$cboAcrDungeon.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($acrDungeonName in @('허상의 정박지', '광기의 동굴', '흩어진 물길')) {
  [void]$cboAcrDungeon.Items.Add($acrDungeonName)
}
$cboAcrDungeon.SelectedIndex = 0
$pnlAcrInput.Controls.Add($cboAcrDungeon)

$updateAcrDifficultyItems = {
  $currentAcrDifficulty = [string]$cboAcrDifficulty.SelectedItem
  $cboAcrDifficulty.Items.Clear()
  foreach ($acrDifficultyName in @('게임 그대로', '입문', '어려움', '매우 어려움')) {
    [void]$cboAcrDifficulty.Items.Add($acrDifficultyName)
  }
  if ($rbAcrParty.Checked) {
    for ($acrHellLevel = 1; $acrHellLevel -le 10; $acrHellLevel++) {
      [void]$cboAcrDifficulty.Items.Add("지옥$acrHellLevel")
    }
  }
  if ($currentAcrDifficulty -and $cboAcrDifficulty.Items.Contains($currentAcrDifficulty)) {
    $cboAcrDifficulty.SelectedItem = $currentAcrDifficulty
  } else {
    $cboAcrDifficulty.SelectedIndex = 0
  }
}
& $updateAcrDifficultyItems

# 함께하기에서만 표시되는 어비스 커스텀 매칭 줄 (파티원 모드는 목록 대상에서 제외).
$pnlAcrMatching = New-Object System.Windows.Forms.Panel
$pnlAcrMatching.Location = New-Object System.Drawing.Point(15, 50)
$pnlAcrMatching.Size = New-Object System.Drawing.Size(524, 26)
$pnlAcrMatching.Visible = $false
$grpContentDetail.Controls.Add($pnlAcrMatching)

$lblAcrMatching = New-Object System.Windows.Forms.Label
$lblAcrMatching.Text = '매칭:'
$lblAcrMatching.Location = New-Object System.Drawing.Point(0, 5)
$lblAcrMatching.Size = New-Object System.Drawing.Size(52, 20)
$pnlAcrMatching.Controls.Add($lblAcrMatching)

$rbAcrChance = New-Object System.Windows.Forms.RadioButton
$rbAcrChance.Text = '우연한 만남'
$rbAcrChance.Location = New-Object System.Drawing.Point(58, 2)
$rbAcrChance.Size = New-Object System.Drawing.Size(110, 22)
$rbAcrChance.Checked = $true
$pnlAcrMatching.Controls.Add($rbAcrChance)

$rbAcrFindParty = New-Object System.Windows.Forms.RadioButton
$rbAcrFindParty.Text = '파티 찾기'
$rbAcrFindParty.Location = New-Object System.Drawing.Point(185, 2)
$rbAcrFindParty.Size = New-Object System.Drawing.Size(95, 22)
$pnlAcrMatching.Controls.Add($rbAcrFindParty)

$rbAcrPartyLead = New-Object System.Windows.Forms.RadioButton
$rbAcrPartyLead.Text = '파티(파티장)'
$rbAcrPartyLead.Location = New-Object System.Drawing.Point(292, 2)
$rbAcrPartyLead.Size = New-Object System.Drawing.Size(120, 22)
$pnlAcrMatching.Controls.Add($rbAcrPartyLead)

# 잠긴(비활성) 라디오 위에서도 자동부활 체크박스처럼 설명이 뜨게 합니다.
# WinForms 는 비활성 컨트롤에 마우스 이벤트를 주지 않아 SetToolTip 이 통하지 않으므로,
# 부모 패널의 MouseMove 로 커서가 어느 라디오 영역에 있는지 직접 판정해 띄웁니다.
# 같은 컨트롤 위에서는 Show 를 다시 부르지 않아 깜박이지 않습니다(2026-07-22 실기 반영).
$acrLockTipText = '리스트의 방식·매칭과 같아야 합니다. 바꾸려면 리스트를 비워 주세요.'
$acrLockTipMove = {
  param($tipSender, $tipArgs)
  if (-not $script:acrLockOn) { return }
  $tipHit = $null
  foreach ($tipCtl in $tipSender.Controls) {
    if ($tipCtl -is [System.Windows.Forms.RadioButton] -and (-not $tipCtl.Enabled) -and
      $tipCtl.Bounds.Contains($tipArgs.Location)) { $tipHit = $tipCtl; break }
  }
  if ($tipHit) {
    if ($script:acrTipShownFor -ne $tipHit) {
      $script:acrTipShownFor = $tipHit
      $toolTip.Show($acrLockTipText, $tipSender, $tipHit.Left, ($tipHit.Bottom + 2), 8000)
    }
  } elseif ($script:acrTipShownFor) {
    $script:acrTipShownFor = $null
    $toolTip.Hide($tipSender)
  }
}
$acrLockTipLeave = {
  param($tipSender, $tipArgs)
  if ($script:acrTipShownFor) {
    $script:acrTipShownFor = $null
    $toolTip.Hide($tipSender)
  }
}
foreach ($acrTipPanel in @($pnlAcrInput, $pnlAcrMatching)) {
  $acrTipPanel.Add_MouseMove($acrLockTipMove)
  $acrTipPanel.Add_MouseLeave($acrLockTipLeave)
}

$lvAcrList = New-Object System.Windows.Forms.ListView
$lvAcrList.Location = New-Object System.Drawing.Point(15, 52)
$lvAcrList.Size = New-Object System.Drawing.Size(420, 150)
$lvAcrList.View = [System.Windows.Forms.View]::Details
$lvAcrList.GridLines = $true
$lvAcrList.CheckBoxes = $true
$lvAcrList.FullRowSelect = $true
$lvAcrList.MultiSelect = $false
$lvAcrList.HideSelection = $false
$lvAcrList.Visible = $false
[void]$lvAcrList.Columns.Add('', 28)
[void]$lvAcrList.Columns.Add('#', 30)
[void]$lvAcrList.Columns.Add('방식', 65)
[void]$lvAcrList.Columns.Add('난이도', 72)
[void]$lvAcrList.Columns.Add('어비스 던전', 110)
[void]$lvAcrList.Columns.Add('매칭', 90)
$grpContentDetail.Controls.Add($lvAcrList)

$lvAcrList.Add_ColumnClick({
    param($acrClickSender, $acrClickArgs)
    if ($acrClickArgs.Column -ne 0 -or $lvAcrList.Items.Count -eq 0) { return }
    $acrAllChecked = $true
    foreach ($acrRow in $lvAcrList.Items) { if (-not $acrRow.Checked) { $acrAllChecked = $false; break } }
    foreach ($acrRow in $lvAcrList.Items) { $acrRow.Checked = -not $acrAllChecked }
  })

$btnAcrAdd = New-Object System.Windows.Forms.Button
$btnAcrAdd.Text = '추가'
$btnAcrAdd.Location = New-Object System.Drawing.Point(445, 52)
$btnAcrAdd.Size = New-Object System.Drawing.Size(94, 30)
$btnAcrAdd.Visible = $false
$grpContentDetail.Controls.Add($btnAcrAdd)

$btnAcrDelete = New-Object System.Windows.Forms.Button
$btnAcrDelete.Text = '삭제(체크)'
$btnAcrDelete.Location = New-Object System.Drawing.Point(445, 88)
$btnAcrDelete.Size = New-Object System.Drawing.Size(94, 30)
$btnAcrDelete.Visible = $false
$grpContentDetail.Controls.Add($btnAcrDelete)

$btnAcrUp = New-Object System.Windows.Forms.Button
$btnAcrUp.Text = '↑ 위로'
$btnAcrUp.Location = New-Object System.Drawing.Point(445, 124)
$btnAcrUp.Size = New-Object System.Drawing.Size(94, 30)
$btnAcrUp.Visible = $false
$grpContentDetail.Controls.Add($btnAcrUp)

$btnAcrDown = New-Object System.Windows.Forms.Button
$btnAcrDown.Text = '↓ 아래로'
$btnAcrDown.Location = New-Object System.Drawing.Point(445, 160)
$btnAcrDown.Size = New-Object System.Drawing.Size(94, 30)
$btnAcrDown.Visible = $false
$grpContentDetail.Controls.Add($btnAcrDown)

$btnAcrAdd.Add_Click({
    $acrMode = $(if ($rbAcrParty.Checked) { 'party' } else { 'solo' })
    $acrMatchingText = '없음'
    if ($rbAcrParty.Checked) {
      if ($rbAcrFindParty.Checked) { $acrMatchingText = '파티 찾기' }
      elseif ($rbAcrPartyLead.Checked) { $acrMatchingText = '파티(파티장)' }
      else { $acrMatchingText = '우연한 만남' }
    }
    Add-AbyssCustomListRow -Mode $acrMode -Difficulty ([string]$cboAcrDifficulty.SelectedItem) `
      -Dungeon ([string]$cboAcrDungeon.SelectedItem) -Matching $acrMatchingText
    Update-AbyssCustomListNumbers
    # 첫 항목이 들어오면 방식·매칭 입력을 그 값으로 잠급니다 (리스트 전체 통일 규칙)
    Update-AbyssInputLock
    if ($script:uiReady) { Save-CustomRepeatToConfig }
  })

$btnAcrDelete.Add_Click({
    $acrCheckedRows = @($lvAcrList.Items | Where-Object { $_.Checked })
    if ($acrCheckedRows.Count -eq 0) {
      Add-GuiLog '[안내] 삭제할 어비스 항목의 앞 체크박스를 선택해 주세요.'
      return
    }
    foreach ($acrRow in $acrCheckedRows) { $lvAcrList.Items.Remove($acrRow) }
    Update-AbyssCustomListNumbers
    # 리스트가 비면 방식·매칭 입력을 다시 열어 줍니다
    Update-AbyssInputLock
    if ($script:uiReady) { Save-CustomRepeatToConfig }
  })

$btnAcrUp.Add_Click({ Move-AbyssCustomListRow -Delta (-1) })
$btnAcrDown.Add_Click({ Move-AbyssCustomListRow -Delta 1 })

$pnlAcrRepeat = New-Object System.Windows.Forms.Panel
$pnlAcrRepeat.Location = New-Object System.Drawing.Point(15, 238)
$pnlAcrRepeat.Size = New-Object System.Drawing.Size(524, 28)
$pnlAcrRepeat.Visible = $false
$grpContentDetail.Controls.Add($pnlAcrRepeat)

$lblAcrRepeat = New-Object System.Windows.Forms.Label
$lblAcrRepeat.Text = '리스트 반복:'
$lblAcrRepeat.Location = New-Object System.Drawing.Point(0, 5)
$lblAcrRepeat.Size = New-Object System.Drawing.Size(80, 20)
$pnlAcrRepeat.Controls.Add($lblAcrRepeat)

$rbAcrInfinite = New-Object System.Windows.Forms.RadioButton
$rbAcrInfinite.Text = '무한'
$rbAcrInfinite.Location = New-Object System.Drawing.Point(85, 2)
$rbAcrInfinite.Size = New-Object System.Drawing.Size(55, 22)
$rbAcrInfinite.Checked = $true
$pnlAcrRepeat.Controls.Add($rbAcrInfinite)

$rbAcrCount = New-Object System.Windows.Forms.RadioButton
$rbAcrCount.Text = '횟수:'
$rbAcrCount.Location = New-Object System.Drawing.Point(145, 2)
$rbAcrCount.Size = New-Object System.Drawing.Size(60, 22)
$pnlAcrRepeat.Controls.Add($rbAcrCount)

$numAcrLaps = New-Object System.Windows.Forms.NumericUpDown
$numAcrLaps.Location = New-Object System.Drawing.Point(205, 0)
$numAcrLaps.Size = New-Object System.Drawing.Size(50, 24)
$numAcrLaps.Minimum = 1
$numAcrLaps.Maximum = 999
$numAcrLaps.Value = 1
$numAcrLaps.Enabled = $false
$pnlAcrRepeat.Controls.Add($numAcrLaps)

$lblAcrLaps = New-Object System.Windows.Forms.Label
$lblAcrLaps.Text = '바퀴'
$lblAcrLaps.Location = New-Object System.Drawing.Point(258, 5)
$lblAcrLaps.Size = New-Object System.Drawing.Size(35, 20)
$pnlAcrRepeat.Controls.Add($lblAcrLaps)

$btnAcrReset = New-Object System.Windows.Forms.Button
$btnAcrReset.Text = '진행 초기화'
$btnAcrReset.Location = New-Object System.Drawing.Point(430, 0)
$btnAcrReset.Size = New-Object System.Drawing.Size(94, 26)
$btnAcrReset.Enabled = $true
$pnlAcrRepeat.Controls.Add($btnAcrReset)

$rbAcrInfinite.Add_CheckedChanged({
    if ($rbAcrInfinite.Checked -and $script:uiReady -and -not $script:crLoading) { Save-CustomRepeatToConfig }
  })
$rbAcrCount.Add_CheckedChanged({
    $numAcrLaps.Enabled = $rbAcrCount.Checked
    if ($rbAcrCount.Checked -and $script:uiReady -and -not $script:crLoading) { Save-CustomRepeatToConfig }
  })
$numAcrLaps.Add_ValueChanged({
    if ($script:uiReady -and -not $script:crLoading) { Save-CustomRepeatToConfig }
  })
$btnAcrReset.Add_Click({
    Reset-CustomProgress -SectionName 'abyssCustomRepeat' `
      -LogMessage '[안내] 어비스 커스텀 반복 진행 기록을 초기화했습니다 - 다음 시작은 리스트 처음(1바퀴째 1번)부터입니다.'
  })
$rbAcrSolo.Add_CheckedChanged({
    & $updateAcrDifficultyItems
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })
$rbAcrParty.Add_CheckedChanged({
    & $updateAcrDifficultyItems
    if ($null -ne $updateCategoryPanels) { & $updateCategoryPanels }
  })

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
$btnRecommendedWindow.Location = New-Object System.Drawing.Point(430, 25)
$btnRecommendedWindow.Size = New-Object System.Drawing.Size(108, 30)
$grpSettings.Controls.Add($btnRecommendedWindow)

# '적용된 설정' 버튼: 설정 그룹에서 켜 둔 항목과 기본 설정 기능(항상 자동 동작)을
# 한 팝업으로 보여줍니다 (설정 저장 버튼 위). 콘텐츠/난이도 등은 화면에서 바로
# 보이므로 팝업에는 넣지 않습니다. 켠 항목만 누를 때 상태를 읽어 표시합니다.
$btnAlwaysOn = New-Object System.Windows.Forms.Button
$btnAlwaysOn.Text = '적용된 설정'
$btnAlwaysOn.Location = New-Object System.Drawing.Point(430, 70)
$btnAlwaysOn.Size = New-Object System.Drawing.Size(108, 30)
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
        try { Save-Config $cfg }
        catch { Add-GuiLog "[경고] 로그 글자 크기 저장 실패: $($_.Exception.Message)" }
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

# 새 버전 안내 링크 (평소 숨김 - 시작 시 최신 버전 확인에서 새 버전이 감지되면
# 버전 표시 대신 이 링크가 나타나고, 클릭하면 GitHub 릴리스 페이지가 열립니다)
$lnkUpdate = New-Object System.Windows.Forms.LinkLabel
$lnkUpdate.Location = New-Object System.Drawing.Point(405, 812)
$lnkUpdate.Size = New-Object System.Drawing.Size(160, 20)
$lnkUpdate.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lnkUpdate.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$lnkUpdate.Visible = $false
$lnkUpdate.Add_LinkClicked({ Start-Process 'https://github.com/Myodong/HoneyNogi/releases/latest' })
$form.Controls.Add($lnkUpdate)

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

# ============================================================
#  커스텀 반복 - 순수 판정 함수 (UI/파일 접근 없음. tests\ 의 진리표 테스트가 이 함수들의
#  사본으로 전진/완주/오류 재시도/지문 판정을 검증합니다 - 판정식을 고치면 사본도 함께 갱신)
# ============================================================
function Format-CustomItemToken {
  # 던전 항목 → "어려움|1-3|1|1|0|1" 6조각(기존 형식 유지),
  # 어비스 항목 → "A|party|어려움|허상의 정박지|우연한 만남" 5조각.
  # 완료 마커 소유자·진행 지문·워커 환경변수가 모두 이 단일 토큰을 사용합니다.
  param($Item)
  $isAbyssItem = $false
  try {
    $isAbyssItem = (([string]$Item.kind -eq 'abyss') -or $null -ne $Item.PSObject.Properties['dungeon'])
  } catch { }
  if ($isAbyssItem) {
    $mode = $(if ([string]$Item.mode -eq 'party') { 'party' } else { 'solo' })
    $difficulty = [string]$Item.difficulty
    if ([string]::IsNullOrWhiteSpace($difficulty)) { $difficulty = '게임 그대로' }
    $matching = $(if ($mode -eq 'party') { [string]$Item.matching } else { '없음' })
    if ([string]::IsNullOrWhiteSpace($matching)) { $matching = '없음' }
    return ('A|{0}|{1}|{2}|{3}' -f $mode, $difficulty, [string]$Item.dungeon, $matching)
  }
  $coinFlag = $(if ([bool]$Item.coin) { '1' } else { '0' })
  $doubleFlag = $(if ([bool]$Item.doubleLoot) { '1' } else { '0' })
  $exhaustFlag = $(if ([bool]$Item.exhaustContinue) { '1' } else { '0' })
  $noDoubleFlag = $(if ([bool]$Item.noDoubleSweep) { '1' } else { '0' })
  return ('{0}|{1}|{2}|{3}|{4}|{5}' -f [string]$Item.difficulty, [string]$Item.stage,
    $coinFlag, $doubleFlag, $exhaustFlag, $noDoubleFlag)
}

function Get-CustomFingerprint {
  # 리스트 전체 → 지문 문자열 (항목 토큰을 ';' 로 연결). 진행 기록 저장 시와 시작 시
  # 이어가기 대조 양쪽에서 이 단일 구현을 사용합니다 (형식 불일치 사고 차단).
  param($Items)
  $tokens = @()
  foreach ($fpItem in @($Items)) {
    if ($null -eq $fpItem) { continue }
    $tokens += (Format-CustomItemToken -Item $fpItem)
  }
  return ($tokens -join ';')
}

function New-CustomMarkerOwnerJson {
  # 완료 마커 소유자: 같은 항목 토큰이 리스트에 중복될 수 있어 항목만으로는 부족합니다.
  # 리스트 전체 지문 + lap/index + 현재 항목 토큰을 함께 기록해 재시작 후에도 정확히 대조합니다.
  param($Context)
  if (-not $Context -or -not $Context.Item) { return '' }
  $owner = [pscustomobject]@{
    version     = 1
    fingerprint = (Get-CustomFingerprint -Items $Context.Items)
    lap         = [int]$Context.Lap
    index       = [int]$Context.Index
    item        = (Format-CustomItemToken -Item $Context.Item)
  }
  return ($owner | ConvertTo-Json -Compress)
}

function Read-CustomMarkerOwner {
  # 구버전 타임스탬프 마커나 부분 파일은 소유자를 확인할 수 없으므로 $null 처리합니다.
  if (-not (Test-Path -LiteralPath $customMarkerFile)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $customMarkerFile -Raw -Encoding UTF8 -ErrorAction Stop
    $owner = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $owner.PSObject.Properties['version'] -or [int]$owner.version -ne 1) { return $null }
    foreach ($required in @('fingerprint', 'lap', 'index', 'item')) {
      if (-not $owner.PSObject.Properties[$required]) { return $null }
    }
    return $owner
  } catch {
    return $null
  }
}

function Test-CustomMarkerOwnerMatchesContext {
  param($Owner, $Context)
  if (-not $Owner -or -not $Context -or -not $Context.Item) { return $false }
  try {
    return (([string]$Owner.fingerprint -eq (Get-CustomFingerprint -Items $Context.Items)) -and
      ([int]$Owner.lap -eq [int]$Context.Lap) -and
      ([int]$Owner.index -eq [int]$Context.Index) -and
      ([string]$Owner.item -eq (Format-CustomItemToken -Item $Context.Item)))
  } catch {
    return $false
  }
}

function Get-CustomNextProgress {
  # 진행(lap/index)을 한 칸 전진시킨 결과를 반환합니다 (저장은 호출부 몫).
  # lap 은 1부터, index 는 0부터(= 다음 실행할 항목). 리스트 끝이면 index=0 으로 감고 lap+1.
  param($Progress, [int]$ItemCount)
  $lap = 1; $index = 0
  if ($Progress) {
    try { $lap = [int]$Progress.lap } catch { $lap = 1 }
    try { $index = [int]$Progress.index } catch { $index = 0 }
  }
  if ($lap -lt 1) { $lap = 1 }
  if ($index -lt 0) { $index = 0 }
  if ($ItemCount -lt 1) { $ItemCount = 1 }
  $index++
  if ($index -ge $ItemCount) { $index = 0; $lap++ }
  return [pscustomobject]@{ lap = $lap; index = $index }
}

function Test-CustomLapComplete {
  # count 모드 완주 판정: 전진 '후'의 lap 이 목표 바퀴 수를 넘는 순간 완주입니다.
  # lap 은 1 시작이므로 N=1 이면 전진 후 lap 이 2가 되는 순간 (off-by-one 주의:
  # '전진 전 lap -ge N' 으로 쓰면 마지막 판을 계상하기 전에 정지하는 사고).
  # 시작 시 '무한으로 돌다 N 축소' 검사도 같은 식(저장된 lap -gt N)을 사용합니다.
  param([string]$ListRepeat, [int]$ListRepeatCount, [int]$Lap)
  if ($ListRepeat -ne 'count') { return $false }
  if ($ListRepeatCount -lt 1) { $ListRepeatCount = 1 }
  return ($Lap -gt $ListRepeatCount)
}

function Get-CustomErrorAction {
  # 오류 종료(코드 1) 대응 판정. ErrorStreak = 지금까지의 같은 항목 연속 오류 횟수(이번 오류 제외).
  # 반환: 'recover' = 완료 마커 있음 - 전진하지 않고 같은 항목의 마무리만 자동 복구
  #       'retry'   = 같은 항목 자동 재시작 (2회까지)
  #       'stop'    = 재시도 상한 초과(같은 항목 3회째 실패) - 정지
  param([bool]$MarkerExists, [int]$ErrorStreak)
  if (($ErrorStreak + 1) -gt 2) { return 'stop' }
  if ($MarkerExists) { return 'recover' }
  return 'retry'
}

function Get-CustomPositionText {
  # 진행 위치 표기: '2바퀴째 3/4번' (index 는 0 시작이므로 표기는 +1)
  param([int]$Lap, [int]$Index, [int]$Total)
  return ('{0}바퀴째 {1}/{2}번' -f $Lap, ($Index + 1), $Total)
}

function Get-CustomItemLabel {
  # 던전/어비스 공용 로그용 항목 표기.
  param($Item)
  $isAbyssItem = $false
  try { $isAbyssItem = ([string]$Item.kind -eq 'abyss') } catch { }
  if ($isAbyssItem) {
    $modeText = $(if ([string]$Item.mode -eq 'party') { '함께하기' } else { '혼자하기' })
    $label = ('{0} {1} {2}' -f $modeText, [string]$Item.difficulty, [string]$Item.dungeon)
    if ([string]$Item.mode -eq 'party') { $label += (", 매칭 '{0}'" -f [string]$Item.matching) }
    return $label
  }
  $label = ('{0} {1}' -f [string]$Item.difficulty, [string]$Item.stage)
  if ([bool]$Item.coin -and [bool]$Item.doubleLoot) { $label += ' (은동전·더블 루팅)' }
  elseif ([bool]$Item.coin) { $label += ' (은동전)' }
  return $label
}

function Get-CustomListCompact {
  # 던전/어비스 리스트 압축 표기 (워커 [설정] 스냅샷 한 줄 기록용).
  # 항목당 '어1-3(20,소·진)' 형식: 괄호 안은 판당 소모량(20/10/0),
  # 더블 루팅이면 noDoubleSweep 를 소(소탕만 진행)/멈(멈춤)으로, 이어서 소진 분기에 도달
  # 가능하면 ·진/·멈(exhaustContinue)을 붙입니다. 소모량 0(미사용)은 '(0)' 만.
  # 예: '1.어1-3(20,소·진) 2.어1-3(20,멈) 3.일2-1(10,멈) 4.일2-3(0)'
  param($Items)
  $parts = @()
  $seq = 0
  foreach ($compactItem in @($Items)) {
    if ($null -eq $compactItem) { continue }
    $seq++
    $isAbyssItem = $false
    try { $isAbyssItem = ([string]$compactItem.kind -eq 'abyss') } catch { }
    if ($isAbyssItem) {
      $modeText = $(if ([string]$compactItem.mode -eq 'party') { '함께' } else { '혼자' })
      $matchingText = $(if ([string]$compactItem.mode -eq 'party') { "/$([string]$compactItem.matching)" } else { '' })
      $parts += ('{0}.{1}/{2}/{3}{4}' -f $seq, $modeText, [string]$compactItem.difficulty,
        [string]$compactItem.dungeon, $matchingText)
      continue
    }
    $difficultyChar = $(if ([string]$compactItem.difficulty -eq '어려움') { '어' } else { '일' })
    $exhaustChar = $(if ([bool]$compactItem.exhaustContinue) { '진' } else { '멈' })
    $suffix = if (-not [bool]$compactItem.coin) { '(0)' }
    elseif (-not [bool]$compactItem.doubleLoot) { ('(10,{0})' -f $exhaustChar) }
    elseif ([bool]$compactItem.noDoubleSweep) { ('(20,소·{0})' -f $exhaustChar) }
    else { '(20,멈)' }   # 더블+멈춤: 소진 분기 도달 불가 - exhaust 표기 생략
    $parts += ('{0}.{1}{2}{3}' -f $seq, $difficultyChar, [string]$compactItem.stage, $suffix)
  }
  return ($parts -join ' ')
}

function Get-CustomCoinTotalPerLap {
  # 리스트 1바퀴에 필요한 은동전 합계 (더블 루팅 20 / 소탕만 10 / 미사용 0).
  # 정상 진행 기준 예산 표시용 - 소진 대응으로 강등되면 실소모는 이보다 적을 수 있음.
  param($Items)
  $total = 0
  foreach ($totalItem in @($Items)) {
    if ($null -eq $totalItem) { continue }
    if ([bool]$totalItem.coin) { $total += $(if ([bool]$totalItem.doubleLoot) { 20 } else { 10 }) }
  }
  return $total
}

function Get-CustomTransitionIssues {
  # 리스트 전환 규칙 검사 (2026-07-20 실기 실측 근거: '다시 하기'로 돌아온 화면은 같은 층
  # 구역만 선택 가능(역방향 포함), 1층→2층은 1-3 결과 화면의 '다음 층으로'로만 가능,
  # 2층→1층은 '나가기(필드행)' 없이는 불가능 - 나가기는 금지이므로 전환 자체를 사전 차단).
  # 검사 대상: 연속 항목 전환(i → i+1) 전부 + 바퀴 순환 전환(마지막 → 첫 항목 - 리스트 반복이
  # 무한이거나 2바퀴 이상일 때만. 1바퀴면 마지막 항목 후 정지라 순환 전환이 발생하지 않음).
  # 위반 규칙: ① 2층 → 1층 전환 금지 ② 1층 → 2층 전환은 출발 항목이 1-3일 때만 허용.
  # 같은 층 전환·같은 구역은 항상 허용 (난이도 차이는 알약 클릭으로 해소 가능 - 제약 없음).
  # 반환: 위반 배열 [{From; To; Wrap; Reason}] (From/To 는 'N번(난이도 구역)' 표기, 없으면 빈 배열).
  # PS 5.1 배열 풀림 주의: 열거용이므로 return $issues 그대로 + 호출부 @() 감싸기 규약.
  param($Items, [string]$ListRepeat, [int]$ListRepeatCount)
  $issues = @()
  $tiList = @()
  foreach ($tiItem in @($Items)) { if ($null -ne $tiItem) { $tiList += $tiItem } }
  if ($tiList.Count -lt 1) { return $issues }
  $tiCheckWrap = (($ListRepeat -ne 'count') -or ($ListRepeatCount -ge 2))
  for ($tiIdx = 0; $tiIdx -lt $tiList.Count; $tiIdx++) {
    $tiWrap = ($tiIdx -eq ($tiList.Count - 1))
    if ($tiWrap -and -not $tiCheckWrap) { continue }
    $tiToIdx = ($tiIdx + 1) % $tiList.Count
    $fromItem = $tiList[$tiIdx]
    $toItem = $tiList[$tiToIdx]
    $fromStage = [string]$fromItem.stage
    $toStage = [string]$toItem.stage
    # 층 번호 추출 ('1-3' → 1). 형식 밖 값은 판정 불가이므로 검사를 건너뜁니다 (방어적 통과 -
    # 실제 리스트는 콤보박스 고정값이라 도달하지 않음)
    $fromFloor = 0; $toFloor = 0
    if ($fromStage -match '^(\d+)-') { $fromFloor = [int]$Matches[1] }
    if ($toStage -match '^(\d+)-') { $toFloor = [int]$Matches[1] }
    if ($fromFloor -lt 1 -or $toFloor -lt 1) { continue }
    if ($fromFloor -eq $toFloor) { continue }
    $tiReason = $null
    if ($fromFloor -gt $toFloor) {
      $tiReason = ('{0}층에서 {1}층으로 내려가는 전환은 게임에서 불가능합니다' -f $fromFloor, $toFloor)
    } elseif ($fromStage -ne '1-3') {
      $tiReason = "1층에서 2층으로 올라가는 전환은 1-3에서만('다음 층으로' 버튼) 가능합니다"
    }
    if ($tiReason) {
      $issues += [pscustomobject]@{
        From   = ('{0}번({1} {2})' -f ($tiIdx + 1), [string]$fromItem.difficulty, $fromStage)
        To     = ('{0}번({1} {2})' -f ($tiToIdx + 1), [string]$toItem.difficulty, $toStage)
        Wrap   = [bool]$tiWrap
        Reason = $tiReason
      }
    }
  }
  return $issues
}

# ============================================================
#  커스텀 반복 - 리스트뷰/설정/진행 기록 헬퍼 (UI·config 접근)
# ============================================================
function Add-CustomListRow {
  # 리스트뷰에 항목 1행 추가 (열: 체크빈칸 / # / 난이도 / 구역 / 은동전 판당 소모량 / 소진 시 / 더블 불가 시).
  # 은동전 열은 더블 루팅까지면 '20개', 소탕만이면 '10개', 미사용이면 '0개' 로 통합 표기.
  # 소진 시 열: 은동전 미사용이면 '—' / 더블+멈춤이면 '—'(소진 분기 도달 불가) / 그 외 진행·멈춤.
  # 더블 불가 시 열: 더블 루팅이 아니면 '—' / noDoubleSweep 이면 '소탕만', 아니면 '멈춤'.
  # (읽기는 Get-CustomItemsFromList 가 이 문자열들을 그대로 역해석하므로 표기 변경 시 함께 수정)
  param([string]$Difficulty, [string]$Stage, [bool]$Coin, [bool]$DoubleLoot,
    [bool]$ExhaustContinue, [bool]$NoDoubleSweep)
  $exhaustText = if (-not $Coin) { '—' }
  elseif ($DoubleLoot -and -not $NoDoubleSweep) { '—' }
  elseif ($ExhaustContinue) { '진행' } else { '멈춤' }
  $noDoubleText = if (-not $DoubleLoot) { '—' }
  elseif ($NoDoubleSweep) { '소탕만' } else { '멈춤' }
  $row = New-Object System.Windows.Forms.ListViewItem('')
  [void]$row.SubItems.Add([string]($lvCrList.Items.Count + 1))
  [void]$row.SubItems.Add($Difficulty)
  [void]$row.SubItems.Add($Stage)
  [void]$row.SubItems.Add($(if ($Coin -and $DoubleLoot) { '20개' } elseif ($Coin) { '10개' } else { '0개' }))
  [void]$row.SubItems.Add($exhaustText)
  [void]$row.SubItems.Add($noDoubleText)
  [void]$lvCrList.Items.Add($row)
}

function Update-CustomListNumbers {
  # 각 행의 # 열을 1부터 다시 매깁니다 (추가/삭제/이동 직후 호출. crLoading 가드로 이벤트 재발화 억제)
  $prevLoading = $script:crLoading
  $script:crLoading = $true
  try {
    for ($rowIndex = 0; $rowIndex -lt $lvCrList.Items.Count; $rowIndex++) {
      $lvCrList.Items[$rowIndex].SubItems[1].Text = [string]($rowIndex + 1)
    }
  } finally { $script:crLoading = $prevLoading }
}

function Move-CustomListRow {
  # 선택한 1줄을 위(-1)/아래(+1)로 이동합니다
  param([int]$Delta)
  if ($lvCrList.SelectedItems.Count -eq 0) { return }
  $row = $lvCrList.SelectedItems[0]
  $fromIndex = $row.Index
  $toIndex = $fromIndex + $Delta
  if ($toIndex -lt 0 -or $toIndex -ge $lvCrList.Items.Count) { return }
  $prevLoading = $script:crLoading
  $script:crLoading = $true
  try {
    $lvCrList.Items.RemoveAt($fromIndex)
    [void]$lvCrList.Items.Insert($toIndex, $row)
    Update-CustomListNumbers
    $row.Selected = $true
    $lvCrList.EnsureVisible($toIndex)
  } finally { $script:crLoading = $prevLoading }
  if ($script:uiReady) { Save-CustomRepeatToConfig }
}

function Get-CustomItemsFromList {
  # 리스트뷰 → 계약 형태 항목 배열(@{difficulty; stage; coin; doubleLoot; exhaustContinue; noDoubleSweep}).
  # 소진 시/더블 불가 시 열의 '—' 는 false 로 읽습니다 ([추가] 시 정규화와 일치 - 도달 불가/무의미 상태).
  # PS 5.1 배열 풀림 주의: 열거용이므로 return $items 그대로 두고 호출부에서 @()로 감쌉니다.
  $items = @()
  foreach ($listRow in $lvCrList.Items) {
    $items += [pscustomobject]@{
      difficulty      = [string]$listRow.SubItems[2].Text
      stage           = [string]$listRow.SubItems[3].Text
      coin            = ($listRow.SubItems[4].Text -ne '0개')
      doubleLoot      = ($listRow.SubItems[4].Text -eq '20개')
      exhaustContinue = ($listRow.SubItems[5].Text -eq '진행')
      noDoubleSweep   = ($listRow.SubItems[6].Text -eq '소탕만')
    }
  }
  return $items
}

function Add-AbyssCustomListRow {
  param([string]$Mode, [string]$Difficulty, [string]$Dungeon, [string]$Matching)
  $normalizedMode = $(if ($Mode -eq 'party' -or $Mode -eq '함께하기') { 'party' } else { 'solo' })
  $modeText = $(if ($normalizedMode -eq 'party') { '함께하기' } else { '혼자하기' })
  $matchingText = $(if ($normalizedMode -eq 'party' -and -not [string]::IsNullOrWhiteSpace($Matching)) { $Matching } else { '—' })
  $row = New-Object System.Windows.Forms.ListViewItem('')
  [void]$row.SubItems.Add([string]($lvAcrList.Items.Count + 1))
  [void]$row.SubItems.Add($modeText)
  [void]$row.SubItems.Add($Difficulty)
  [void]$row.SubItems.Add($Dungeon)
  [void]$row.SubItems.Add($matchingText)
  [void]$lvAcrList.Items.Add($row)
}

function Update-AbyssCustomListNumbers {
  $prevLoading = $script:crLoading
  $script:crLoading = $true
  try {
    for ($rowIndex = 0; $rowIndex -lt $lvAcrList.Items.Count; $rowIndex++) {
      $lvAcrList.Items[$rowIndex].SubItems[1].Text = [string]($rowIndex + 1)
    }
  } finally { $script:crLoading = $prevLoading }
}

function Move-AbyssCustomListRow {
  param([int]$Delta)
  if ($lvAcrList.SelectedItems.Count -eq 0) { return }
  $row = $lvAcrList.SelectedItems[0]
  $fromIndex = $row.Index
  $toIndex = $fromIndex + $Delta
  if ($toIndex -lt 0 -or $toIndex -ge $lvAcrList.Items.Count) { return }
  $prevLoading = $script:crLoading
  $script:crLoading = $true
  try {
    $lvAcrList.Items.RemoveAt($fromIndex)
    [void]$lvAcrList.Items.Insert($toIndex, $row)
    Update-AbyssCustomListNumbers
    $row.Selected = $true
    $lvAcrList.EnsureVisible($toIndex)
  } finally { $script:crLoading = $prevLoading }
  # 순서가 바뀌면 기준이 되는 첫 항목도 바뀔 수 있어 잠금을 다시 계산합니다
  Update-AbyssInputLock
  if ($script:uiReady) { Save-CustomRepeatToConfig }
}

function Get-AbyssCustomItemsFromList {
  $items = @()
  foreach ($listRow in $lvAcrList.Items) {
    $mode = $(if ($listRow.SubItems[2].Text -eq '함께하기') { 'party' } else { 'solo' })
    $items += [pscustomobject]@{
      kind       = 'abyss'
      mode       = $mode
      difficulty = [string]$listRow.SubItems[3].Text
      dungeon    = [string]$listRow.SubItems[4].Text
      matching   = $(if ($mode -eq 'party') { [string]$listRow.SubItems[5].Text } else { '없음' })
    }
  }
  return $items
}

function Get-AbyssListLock {
  # 어비스 커스텀 리스트의 '방식·매칭 고정값'을 첫 항목에서 뽑습니다 (2026-07-22 사용자 확정:
  # 리스트 전체가 같은 방식+매칭이어야 함 - 항목마다 다르면 파티 상태가 항목 간에 꼬임).
  # 반환: 리스트가 비었으면 $null, 아니면 단일 해시테이블 @{ Mode; Matching }
  #       (Mode = 'solo'/'party', Matching = 혼자하기면 '없음', 함께하기면 GUI 표기 문구).
  # 단일 객체 반환이라 PS 5.1 배열 풀림과 무관합니다 - 호출부는 $null 검사만 하면 됩니다.
  param($Items)
  $alList = @()
  foreach ($alItem in @($Items)) { if ($null -ne $alItem) { $alList += $alItem } }
  if ($alList.Count -lt 1) { return $null }
  $alFirst = $alList[0]
  $alMode = $(if ([string]$alFirst.mode -eq 'party' -or [string]$alFirst.mode -eq '함께하기') { 'party' } else { 'solo' })
  $alMatching = '없음'
  if ($alMode -eq 'party') {
    # config 를 직접 편집해 '파티찾기'(공백 없음)처럼 적혀 있어도 같은 값으로 보도록 공백을 지워 비교하고,
    # 라디오에 되돌려 맞출 수 있게 GUI 표기 문구로 정규화합니다.
    $alKey = ([string]$alFirst.matching) -replace '\s', ''
    switch ($alKey) {
      '파티찾기'     { $alMatching = '파티 찾기' }
      '파티(파티장)' { $alMatching = '파티(파티장)' }
      default        { $alMatching = '우연한 만남' }
    }
  }
  return @{ Mode = $alMode; Matching = $alMatching }
}

function Get-AbyssMatchingIssues {
  # 첫 항목과 방식·매칭이 다른 항목들을 찾아 돌려줍니다 (config 를 직접 편집해 섞인 리스트가
  # 들어온 경우의 시작 게이트용 - GUI 에서는 라디오 잠금으로 애초에 섞이지 않습니다).
  # 반환: 위반 배열 [{Index; Mode; Matching; Reason}] (없으면 빈 배열).
  # PS 5.1 배열 풀림 주의: 열거용이므로 return $issues 그대로 + 호출부 @() 감싸기 규약.
  param($Items)
  $issues = @()
  $amList = @()
  foreach ($amItem in @($Items)) { if ($null -ne $amItem) { $amList += $amItem } }
  if ($amList.Count -lt 2) { return $issues }
  $amLock = Get-AbyssListLock -Items $amList
  if ($null -eq $amLock) { return $issues }
  $amLockKey = ([string]$amLock.Matching) -replace '\s', ''
  for ($amIdx = 1; $amIdx -lt $amList.Count; $amIdx++) {
    $amItemCur = $amList[$amIdx]
    $amMode = $(if ([string]$amItemCur.mode -eq 'party' -or [string]$amItemCur.mode -eq '함께하기') { 'party' } else { 'solo' })
    $amMatching = $(if ($amMode -eq 'party') { [string]$amItemCur.matching } else { '없음' })
    $amKey = $amMatching -replace '\s', ''
    $amModeText = $(if ($amMode -eq 'party') { '함께하기' } else { '혼자하기' })
    $amLockModeText = $(if ($amLock.Mode -eq 'party') { '함께하기' } else { '혼자하기' })
    $amReason = $null
    if ($amMode -ne $amLock.Mode) {
      $amReason = ("리스트의 방식은 '{0}'인데 이 항목은 '{1}'입니다" -f $amLockModeText, $amModeText)
    } elseif ($amMode -eq 'party' -and $amKey -ne $amLockKey) {
      $amReason = ("리스트의 매칭은 '{0}'인데 이 항목은 '{1}'입니다" -f [string]$amLock.Matching, $amMatching)
    }
    if ($amReason) {
      $issues += [pscustomobject]@{
        Index    = ($amIdx + 1)
        Mode     = $amModeText
        Matching = $amMatching
        Reason   = $amReason
      }
    }
  }
  return $issues
}

function Update-AbyssInputLock {
  # 어비스 커스텀 입력 줄 잠금: 리스트에 항목이 하나라도 있으면 그 리스트의 방식·매칭으로
  # 라디오를 맞추고 비활성화합니다 (팝업 대신 애초에 못 고르게 하는 방식 - 사용자 확정).
  # 리스트가 비면 전부 다시 활성화합니다. 항목 추가/삭제/이동/설정 복원/카테고리 전환 후 호출.
  # 라디오 Checked 를 코드로 바꾸면 CheckedChanged → 패널 갱신 → 이 함수 재호출로 이어질 수
  # 있어 $script:acrLockUpdating 로 재진입을 막습니다.
  if ($script:acrLockUpdating) { return }
  $script:acrLockUpdating = $true
  try {
    $acrLock = Get-AbyssListLock -Items @(Get-AbyssCustomItemsFromList)
    $acrLockOn = ($null -ne $acrLock)
    $prevLoading = $script:crLoading
    $script:crLoading = $true
    try {
      if ($acrLockOn) {
        if ($acrLock.Mode -eq 'party') {
          if (-not $rbAcrParty.Checked) { $rbAcrParty.Checked = $true }
          if ($acrLock.Matching -eq '파티 찾기') {
            if (-not $rbAcrFindParty.Checked) { $rbAcrFindParty.Checked = $true }
          } elseif ($acrLock.Matching -eq '파티(파티장)') {
            if (-not $rbAcrPartyLead.Checked) { $rbAcrPartyLead.Checked = $true }
          } else {
            if (-not $rbAcrChance.Checked) { $rbAcrChance.Checked = $true }
          }
        } else {
          if (-not $rbAcrSolo.Checked) { $rbAcrSolo.Checked = $true }
        }
      }
      $rbAcrSolo.Enabled = -not $acrLockOn
      $rbAcrParty.Enabled = -not $acrLockOn
      $rbAcrChance.Enabled = -not $acrLockOn
      $rbAcrFindParty.Enabled = -not $acrLockOn
      $rbAcrPartyLead.Enabled = -not $acrLockOn
    } finally { $script:crLoading = $prevLoading }
    # 잠긴 이유 안내: 항상 보이는 라벨이 주 수단입니다.
    # (툴팁은 비활성 컨트롤에 안 뜨는 WinForms 특성 때문에 라디오+패널에 겹쳐 걸었더니
    #  마우스가 둘 사이를 오갈 때 깜박였음 - 2026-07-22 실기 확인 → 패널에만 남깁니다)
    # 툴팁은 아래 MouseMove 핸들러가 잠긴 라디오 위에서만 직접 띄웁니다
    # (비활성 컨트롤은 마우스 이벤트를 받지 못해 SetToolTip 이 동작하지 않는 WinForms 특성)
    $script:acrLockOn = $acrLockOn
    if (-not $acrLockOn -and $script:acrTipShownFor) {
      $script:acrTipShownFor = $null
      $toolTip.Hide($pnlAcrInput)
      $toolTip.Hide($pnlAcrMatching)
    }
  } finally { $script:acrLockUpdating = $false }
}

function Set-CustomRepeatOnConfig {
  # customRepeat 섹션을 현재 UI 상태로 갱신합니다 (Save-Config 는 호출부 몫).
  # progress 는 절대 건드리지 않고 그대로 옮겨 담습니다 (진행 기록 비파괴 원칙).
  # enabled 는 라디오가 아니라 $script:customEnabledWish 를 기록합니다 - 던전 외 카테고리에서
  # 라디오가 표시상 무한 반복으로 폴백해 있어도 선택 의도가 보존되게 (요청사항 확정 스펙).
  param($Config)
  $prevProgress = $null
  if ($Config.PSObject.Properties['customRepeat'] -and $Config.customRepeat -and
      $Config.customRepeat.PSObject.Properties['progress']) {
    $prevProgress = $Config.customRepeat.progress
  }
  $node = [pscustomobject]@{
    '_설명'         = "'던전 커스텀 반복' 설정입니다. items 리스트를 위에서부터 순서대로 1판씩 실행합니다. enabled 는 던전/어비스 공용 커스텀 반복 선택 상태이며 progress 는 이어가기용 진행 기록입니다."
    enabled         = [bool]$script:customEnabledWish
    '_items'        = '각 항목: difficulty/stage/coin/doubleLoot + exhaustContinue(동전 소진 시 true=미사용으로 진행, false=멈춤) / noDoubleSweep(더블 루팅 불가 시 true=소탕만 진행, false=멈춤). 소진/더블 대응은 항목별 속성입니다'
    items           = [array]@(Get-CustomItemsFromList)
    listRepeat      = $(if ($rbCrCount.Checked) { 'count' } else { 'infinite' })
    listRepeatCount = [int]$numCrLaps.Value
    progress        = $prevProgress
  }
  if ($Config.PSObject.Properties['customRepeat']) { $Config.customRepeat = $node }
  else { $Config | Add-Member -NotePropertyName 'customRepeat' -NotePropertyValue $node }
}

function Set-AbyssCustomRepeatOnConfig {
  param($Config)
  $prevProgress = $null
  if ($Config.PSObject.Properties['abyssCustomRepeat'] -and $Config.abyssCustomRepeat -and
      $Config.abyssCustomRepeat.PSObject.Properties['progress']) {
    $prevProgress = $Config.abyssCustomRepeat.progress
  }
  $node = [pscustomobject]@{
    '_설명'         = "'어비스 커스텀 반복' 모드 설정입니다. items 리스트를 위에서부터 순서대로 1판씩 실행합니다. progress 는 이어가기용 진행 기록이므로 직접 수정하지 마세요."
    '_items'        = "각 항목: kind=abyss / mode(solo 또는 party) / difficulty / dungeon / matching. 혼자하기 항목의 matching 은 '없음'입니다."
    items           = [array]@(Get-AbyssCustomItemsFromList)
    listRepeat      = $(if ($rbAcrCount.Checked) { 'count' } else { 'infinite' })
    listRepeatCount = [int]$numAcrLaps.Value
    progress        = $prevProgress
  }
  if ($Config.PSObject.Properties['abyssCustomRepeat']) { $Config.abyssCustomRepeat = $node }
  else { $Config | Add-Member -NotePropertyName 'abyssCustomRepeat' -NotePropertyValue $node }
}

function Save-CustomRepeatToConfig {
  # 던전/어비스 커스텀 설정 공용 즉시 저장 경로.
  $cfg = Read-Config
  if (-not $cfg) {
    Add-GuiLog '[경고] config.json 을 읽지 못해 커스텀 반복 설정을 저장하지 못했습니다.'
    return
  }
  Set-CustomRepeatOnConfig -Config $cfg
  Set-AbyssCustomRepeatOnConfig -Config $cfg
  try { Save-Config $cfg }
  catch {
    Add-GuiLog "[경고] 커스텀 반복 설정 저장 실패: $($_.Exception.Message)"
  }
  Update-CustomCoinTotalLabel
}

function Update-CustomCoinTotalLabel {
  # 하단 줄의 은동전 예산 라벨 갱신 (리스트 편집·리스트 반복 설정 변경·복원 시 호출).
  # 무한이면 바퀴당 합계, 횟수 N바퀴면 총합(합계 x N)을 표시합니다.
  $totalItems = @(Get-CustomItemsFromList)
  $perLap = Get-CustomCoinTotalPerLap -Items $totalItems
  if ($rbCrCount.Checked) {
    # 횟수 모드: 바퀴당과 총합(x N)을 같이 표시
    $lblCrCoinTotal.Text = ('바퀴당 {0:N0} · 총 {1:N0}개' -f $perLap, ($perLap * [int]$numCrLaps.Value))
  } else {
    $lblCrCoinTotal.Text = ('바퀴당 은동전 {0:N0}개' -f $perLap)
  }
}

function Get-CustomCurrentContext {
  # 이번 회차에 실행할 항목/위치 정보를 config 에서 읽습니다 (단일 해시테이블 반환 - 배열 풀림 무관).
  # 반환: @{ Items; Total; Lap; Index; Item; ListRepeat; ListRepeatCount; Position } 또는 $null
  param([string]$SectionName = $script:customConfigSection)
  $cfg = Read-Config
  if ([string]::IsNullOrWhiteSpace($SectionName)) { $SectionName = 'customRepeat' }
  if (-not $cfg -or -not $cfg.PSObject.Properties[$SectionName] -or -not $cfg.$SectionName) { return $null }
  $node = $cfg.$SectionName
  $items = @()
  if ($node.PSObject.Properties['items']) { $items = @($node.items) }
  if ($items.Count -eq 0) { return $null }
  $lap = 1; $index = 0
  if ($node.PSObject.Properties['progress'] -and $node.progress) {
    try { $lap = [int]$node.progress.lap } catch { $lap = 1 }
    try { $index = [int]$node.progress.index } catch { $index = 0 }
  }
  if ($lap -lt 1) { $lap = 1 }
  if ($index -lt 0 -or $index -ge $items.Count) { $index = 0 }
  $listRepeat = 'infinite'
  if ($node.PSObject.Properties['listRepeat']) { try { $listRepeat = [string]$node.listRepeat } catch { } }
  $listRepeatCount = 1
  if ($node.PSObject.Properties['listRepeatCount']) { try { $listRepeatCount = [int]$node.listRepeatCount } catch { } }
  return @{
    Items           = $items
    Total           = $items.Count
    Lap             = $lap
    Index           = $index
    Item            = $items[$index]
    ListRepeat      = $listRepeat
    ListRepeatCount = $listRepeatCount
    SectionName     = $SectionName
    Position        = (Get-CustomPositionText -Lap $lap -Index $index -Total $items.Count)
  }
}

function Step-CustomProgress {
  # 판 완료 계상: progress 를 한 칸 전진시키고 '즉시' 디스크에 저장합니다.
  # 전진 후 progress 를 반환합니다 (호출부가 Test-CustomLapComplete 로 완주를 판정).
  # 저장 실패(파일 잠금 등)는 $null을 반환해 호출부가 다음 회차를 시작하지 않게 합니다.
  param([string]$SectionName = $script:customConfigSection)
  $cfg = Read-Config
  if ([string]::IsNullOrWhiteSpace($SectionName)) { $SectionName = 'customRepeat' }
  if (-not $cfg -or -not $cfg.PSObject.Properties[$SectionName] -or -not $cfg.$SectionName) {
    Add-GuiLog '[경고] config 를 읽지 못해 커스텀 진행 기록을 전진시키지 못했습니다.'
    return $null
  }
  $node = $cfg.$SectionName
  $items = @()
  if ($node.PSObject.Properties['items']) { $items = @($node.items) }
  $prevProgress = $null
  if ($node.PSObject.Properties['progress'] -and $node.progress) { $prevProgress = $node.progress }
  $next = Get-CustomNextProgress -Progress $prevProgress -ItemCount $items.Count
  $newProgress = [pscustomobject]@{
    lap         = [int]$next.lap
    index       = [int]$next.index
    fingerprint = (Get-CustomFingerprint -Items $items)
  }
  if ($node.PSObject.Properties['progress']) { $node.progress = $newProgress }
  else { $node | Add-Member -NotePropertyName 'progress' -NotePropertyValue $newProgress }
  try {
    Save-Config $cfg
  } catch {
    Add-GuiLog "[오류] 커스텀 진행 기록 저장 실패: $($_.Exception.Message) - 중복 실행 방지를 위해 다음 판을 시작하지 않습니다."
    return $null
  }
  return $newProgress
}

function Reset-CustomProgress {
  # 진행 기록 삭제(progress = null). 진행 초기화 버튼 / 시작 시 지문 불일치 / 완주 / lap 초과 4곳 공용
  # 반환: 디스크 저장까지 성공했으면 $true, 읽기/저장 실패면 $false.
  param([string]$LogMessage = '', [string]$SectionName = $script:customConfigSection)
  $cfg = Read-Config
  if ([string]::IsNullOrWhiteSpace($SectionName)) { $SectionName = 'customRepeat' }
  if (-not $cfg -or -not $cfg.PSObject.Properties[$SectionName] -or -not $cfg.$SectionName) {
    Add-GuiLog '[오류] config 를 읽지 못해 커스텀 진행 기록을 초기화하지 못했습니다.'
    return $false
  }
  $node = $cfg.$SectionName
  if ($node.PSObject.Properties['progress']) { $node.progress = $null }
  else { $node | Add-Member -NotePropertyName 'progress' -NotePropertyValue $null }
  try {
    Save-Config $cfg
  } catch {
    Add-GuiLog "[오류] 커스텀 진행 초기화 저장 실패: $($_.Exception.Message)"
    return $false
  }
  if ($LogMessage) { Add-GuiLog $LogMessage }
  return $true
}

function Clear-CustomEnv {
  # GUI 프로세스의 환경변수는 회차/모드 전환 뒤에도 남습니다. HONEYNOGI_CUSTOM_ITEM 이 남아
  # 있으면 워커가 '존재 = 커스텀 모드' 규약 때문에 어비스/사냥터 회차를 커스텀으로 오동작하므로,
  # 비커스텀 회차 시작 전과 정지(Stop-AllRun) 시 반드시 전부 제거합니다.
  # (HONEYNOGI_REPEAT_INFO 는 기존 변수라 매 회차 덮어쓰므로 정리 불필요)
  foreach ($envName in @('HONEYNOGI_CUSTOM_ITEM', 'HONEYNOGI_CUSTOM_PREV', 'HONEYNOGI_CUSTOM_NEXT',
      'HONEYNOGI_CUSTOM_RESTART', 'HONEYNOGI_CUSTOM_RECOVERY', 'HONEYNOGI_CUSTOM_POSITION',
      'HONEYNOGI_CUSTOM_LIST', 'HONEYNOGI_CUSTOM_MARKER', 'HONEYNOGI_CUSTOM_OWNER')) {
    Remove-Item -LiteralPath "Env:\$envName" -ErrorAction SilentlyContinue
  }
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
      try { $rbNdExhaustGo.Checked = [bool]$nd.continueWithoutCoin } catch { $rbNdExhaustStop.Checked = $true }
      # 두 번째 단계는 더블 루팅이 켜져 있을 때만 유효합니다.
      try { $rbNdNoDoubleSweep.Checked = ([bool]$nd.continueSweepOnly -and $chkNdDoubleLoot.Checked) } catch { $rbNdNoDoubleStop.Checked = $true }
      if ([string]$nd.matching -eq '우연한 만남') { $rbNdChance.Checked = $true } else { $rbNdFindParty.Checked = $true }
    }
  } catch { }
  # 저장된 커스텀 반복 설정 복원 (리스트/반복 방식/소진 대응. progress 는 UI에 표시하지 않고
  # 시작 시 판정합니다. 카테고리 복원이 위에서 먼저 실행되므로 이 위치가 안전 - 던전이면 라디오 복원)
  try {
    if ($cfg.PSObject.Properties['customRepeat'] -and $cfg.customRepeat) {
      $cr = $cfg.customRepeat
      $script:crLoading = $true
      try {
        $lvCrList.Items.Clear()
        if ($cr.PSObject.Properties['items']) {
          foreach ($crSavedItem in @($cr.items)) {
            if ($null -eq $crSavedItem) { continue }
            # 구버전(계약 v1) config 항목에는 exhaustContinue/noDoubleSweep 가 없음 - [bool]$null = false(멈춤)
            Add-CustomListRow -Difficulty ([string]$crSavedItem.difficulty) -Stage ([string]$crSavedItem.stage) `
              -Coin ([bool]$crSavedItem.coin) -DoubleLoot ([bool]$crSavedItem.doubleLoot) `
              -ExhaustContinue ([bool]$crSavedItem.exhaustContinue) -NoDoubleSweep ([bool]$crSavedItem.noDoubleSweep)
          }
        }
        Update-CustomListNumbers
        if ([string]$cr.listRepeat -eq 'count') { $rbCrCount.Checked = $true } else { $rbCrInfinite.Checked = $true }
        try { $numCrLaps.Value = [Math]::Min(999, [Math]::Max(1, [int]$cr.listRepeatCount)) } catch { $numCrLaps.Value = 1 }
        Update-CustomCoinTotalLabel
        # 선택 의도 복원: 던전이 아닌 카테고리로 저장돼 있어도 enabled 는 의도로 보존하고,
        # 던전/어비스 카테고리일 때 라디오를 실제로 켭니다 (사냥터는 커스텀 미지원).
        $script:customEnabledWish = $false
        if ($cr.PSObject.Properties['enabled'] -and [bool]$cr.enabled) { $script:customEnabledWish = $true }
        if ($script:customEnabledWish -and -not $rbCatHunting.Checked) { $rbCustomRepeat.Checked = $true }
      } finally { $script:crLoading = $false }
    }
  } catch { $script:crLoading = $false }
  # 저장된 어비스 커스텀 반복 목록/반복 방식 복원. 진행 기록은 시작 시 지문과 함께 판정합니다.
  try {
    if ($cfg.PSObject.Properties['abyssCustomRepeat'] -and $cfg.abyssCustomRepeat) {
      $acr = $cfg.abyssCustomRepeat
      $script:crLoading = $true
      try {
        $lvAcrList.Items.Clear()
        if ($acr.PSObject.Properties['items']) {
          foreach ($acrSavedItem in @($acr.items)) {
            if ($null -eq $acrSavedItem) { continue }
            Add-AbyssCustomListRow -Mode ([string]$acrSavedItem.mode) `
              -Difficulty ([string]$acrSavedItem.difficulty) -Dungeon ([string]$acrSavedItem.dungeon) `
              -Matching ([string]$acrSavedItem.matching)
          }
        }
        Update-AbyssCustomListNumbers
        if ([string]$acr.listRepeat -eq 'count') { $rbAcrCount.Checked = $true } else { $rbAcrInfinite.Checked = $true }
        try { $numAcrLaps.Value = [Math]::Min(999, [Math]::Max(1, [int]$acr.listRepeatCount)) } catch { $numAcrLaps.Value = 1 }
        $numAcrLaps.Enabled = $rbAcrCount.Checked
      } finally { $script:crLoading = $false }
      # 복원된 리스트 기준으로 방식·매칭 입력 잠금을 맞춥니다 (통일 규칙)
      Update-AbyssInputLock
    }
  } catch { $script:crLoading = $false }
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
    '_continueWithoutCoin' = '동전 소진 시(잔량 10 미만): true=미사용으로 진행 / false=멈춤'
    continueWithoutCoin = [bool]($chkNdCoin.Checked -and $rbNdExhaustGo.Checked)
    '_continueSweepOnly' = '더블 루팅 불가 시(잔량 10~19): true=소탕만 진행 / false=멈춤'
    continueSweepOnly   = [bool]($chkNdCoin.Checked -and $chkNdDoubleLoot.Checked -and $rbNdNoDoubleSweep.Checked)
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
  # 커스텀 반복 설정도 같은 config 객체에 함께 동기화합니다 (progress 는 보존 -
  # 별도 Read/Save 를 하면 아래 Save-Config 가 되돌려 덮어쓰므로 반드시 이 객체에 병합)
  Set-CustomRepeatOnConfig -Config $cfg
  Set-AbyssCustomRepeatOnConfig -Config $cfg

  try {
    Save-Config $cfg
  } catch {
    Add-GuiLog "[오류] config.json 저장 실패: $($_.Exception.Message)"
    return $false
  }
  return $true
}

function Set-UiRunning {
  param([bool]$IsRunning)
  $script:running = $IsRunning
  $btnStart.Enabled = -not $IsRunning
  $btnSafeStop.Enabled = $IsRunning
  $btnKill.Enabled = $IsRunning
  # 대기 중에는 시작만, 실행 중에는 중지 2개만 표시 (시작 자리에 중지가 나타남 - 오클릭 방지)
  $btnStart.Visible = -not $IsRunning
  $btnSafeStop.Visible = $IsRunning
  $btnKill.Visible = $IsRunning
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

function Move-WorkerLogToArchive {
  param(
    [string]$Path,
    [string]$Suffix = ''
  )

  if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
  try {
    $archiveStamp = (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTime.ToString('yyyyMMdd_\hHH\mmm\sss')
    $archivePath = Join-Path $scriptRoot ("Log\run_{0}{1}.log" -f $archiveStamp, $Suffix)
    Move-Item -LiteralPath $Path -Destination $archivePath -Force -ErrorAction Stop
    return [long]0
  } catch {
    # 외부 프로그램이 파일을 잠갔으면 과거 내용은 GUI에 다시 표시하지 않고, 워커가 기본 로그를
    # 열 수 없을 때 사용할 복구 로그를 별도로 감시합니다.
    try { return [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length }
    catch { return [long]0 }
  }
}

function Start-NextCycle {
  $cycleNumber = $script:completedCycles + 1
  # 지난 세션(또는 직전 회차)의 로그 파일이 남아 있으면, 워커가 새로 쓰기 전에
  # GUI 타이머가 그 내용을 '새 로그'로 착각해 화면에 다시 출력합니다.
  # 워커 시작 전에 파일을 치워 과거 로그가 다시 뜨지 않게 하되, 그냥 지우지 않고
  # run_시각.log 로 보관해 지난 회차 로그를 최근 10개까지 남깁니다 (오류 세트 보관 개수와 동일).
  # 시각은 읽기 쉽게 h/m/s 표기를 씁니다 (예: run_20260718_h21m49s09.log).
  $script:logOffset = Move-WorkerLogToArchive -Path $workerLog
  $script:recoveryLogOffset = Move-WorkerLogToArchive -Path $workerRecoveryLog -Suffix '_recovery'
  # 보관 개수(10개) 초과분은 오래된 것부터 삭제 (정리는 파일명이 아니라 수정 시각 기준이라
  # 옛 형식과 복구 로그가 섞여 있어도 함께 정리됩니다)
  $oldRunLogs = @(Get-ChildItem -Path (Join-Path $scriptRoot 'Log') -Filter 'run_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 10)
  foreach ($oldLog in $oldRunLogs) { Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction SilentlyContinue }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $workerScript + '"'))
  # 반복 모드와 앱 버전은 config에 없는 GUI 쪽 정보라 환경변수로 워커에 전달합니다.
  # 워커가 이 값을 로그 파일의 [설정] 스냅샷(화면 미표시)에 함께 기록합니다.
  $env:HONEYNOGI_APP_VERSION = $appVersion
  $customContext = $null
  if ($script:customActive) {
    $customContext = Get-CustomCurrentContext
    if (-not $customContext) {
      # 실행 중에는 리스트 편집이 비활성이라 정상 경로에선 없지만, config 읽기 실패 등 방어
      Add-GuiLog '[오류] 커스텀 반복 정보를 config 에서 읽지 못해 정지합니다.'
      Stop-AllRun '커스텀 반복 정보 읽기 실패'
      return
    }
  }
  if ($customContext) {
    # 커스텀 반복: 워커 실행 환경변수 세트 (HONEYNOGI_CUSTOM_ITEM 존재 = 워커 커스텀 모드)
    $env:HONEYNOGI_CUSTOM_ITEM = Format-CustomItemToken -Item $customContext.Item
    $env:HONEYNOGI_CUSTOM_PREV = $script:customPrevItem
    # 다음 항목(리스트 순환) - 워커가 결과 화면에서 '다시 하기'(다음도 같은 구역) vs
    # '나가기 → 선택 화면'(다른 구역)을 결정하는 데 씁니다. 다시 하기로 온 옵션 화면에는
    # 좌상단 '<' 가 없다는 실측(2026-07-20) 때문에 회차 마무리 시점에 갈림길을 정해야 합니다.
    # 1항목 리스트면 다음 = 자기 자신(같은 구역) → 기존처럼 다시 하기.
    $customNextIndex = ($customContext.Index + 1) % [Math]::Max(1, [int]$customContext.Total)
    $env:HONEYNOGI_CUSTOM_NEXT = Format-CustomItemToken -Item (@($customContext.Items)[$customNextIndex])
    $env:HONEYNOGI_CUSTOM_RESTART = $(if ($script:customRestart) { '1' } else { '' })
    $env:HONEYNOGI_CUSTOM_RECOVERY = $(if ($script:customRecoveryPending) { '1' } else { '' })
    $env:HONEYNOGI_CUSTOM_POSITION = $customContext.Position
    $env:HONEYNOGI_CUSTOM_LIST = Get-CustomListCompact -Items $customContext.Items
    $env:HONEYNOGI_CUSTOM_MARKER = $customMarkerFile
    $env:HONEYNOGI_CUSTOM_OWNER = New-CustomMarkerOwnerJson -Context $customContext
    $repeatModeText = $(if ($customContext.ListRepeat -eq 'count') { "$($customContext.ListRepeatCount)바퀴" } else { '무한' })
    $env:HONEYNOGI_REPEAT_INFO = "커스텀 반복(항목 $($customContext.Total)개, $($customContext.Lap)바퀴째 $($customContext.Index + 1)번, $repeatModeText)"
    # 일반 회차는 이전 마커를 삭제하고 시작합니다. 마무리 복구 회차는 현재 항목이 이미 클리어됐다는
    # 근거이자 GUI 재시작 복구 정보이므로 같은 소유자의 마커를 보존합니다.
    # 일반 회차에서 삭제 실패(파일 잠금 등) 시에는 이번 회차 마커를 무시해 오계상을 막습니다.
    $script:customMarkerIgnore = $false
    if ((-not $script:customRecoveryPending) -and (Test-Path -LiteralPath $customMarkerFile)) {
      Remove-Item -LiteralPath $customMarkerFile -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $customMarkerFile) {
        Add-GuiLog '[경고] 이전 완료 마커 파일을 삭제하지 못했습니다 - 이번 회차는 마커를 무시합니다 (완료 계상은 정상 종료 코드로만).'
        $script:customMarkerIgnore = $true
      }
    }
  } else {
    # 비커스텀 회차: GUI 프로세스에 잔존한 커스텀 환경변수를 정리합니다
    # (남으면 어비스/사냥터 워커가 커스텀 모드로 오동작 - Clear-CustomEnv 주석 참고)
    Clear-CustomEnv
    $env:HONEYNOGI_REPEAT_INFO = if ($null -ne $script:targetTime) {
      "시간 지정(~$($script:targetTime.ToString('MM-dd HH:mm')))"
    } elseif ($script:targetCycles -gt 0) {
      "횟수 지정(${cycleNumber}/$($script:targetCycles)회차)"
    } else { '무한 반복' }
  }
  $script:worker = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arguments -PassThru
  if ($customContext) {
    $lblStatus.Text = "커스텀: $($customContext.Position) 실행 중"
  } else {
    $statusSuffix = ''
    if ($null -ne $script:targetTime) { $statusSuffix = " ($($script:targetTime.ToString('HH:mm')) 까지)" }
    $lblStatus.Text = "${cycleNumber}회차 실행 중...$statusSuffix"
  }
  $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
  if ($customContext) {
    Add-GuiLog "=== ${cycleNumber}회차 시작($($customContext.Index + 1)/$($customContext.Total)) ==="
  } else {
    Add-GuiLog "=== ${cycleNumber}회차 시작 ==="
  }
}

function Stop-AllRun {
  param([string]$Reason)
  $wasCustom = $script:customActive
  $workerToDispose = $script:worker
  if ($workerToDispose) {
    $workerWasKilled = $false
    try {
      if (-not $workerToDispose.HasExited) {
        $workerToDispose.Kill()
        $workerToDispose.WaitForExit()
        $workerWasKilled = $true
      }
    } catch { }
    finally {
      try { $workerToDispose.Dispose() } catch { }
      $script:worker = $null
    }
    if ($workerWasKilled) {
      # Kill 시점이 키/마우스 '누름-뗌' 사이였을 수 있으므로 입력 상태를 정리합니다
      Release-StuckInput
    }
  }
  $script:worker = $null
  Set-UiRunning $false
  $script:stopRequested = $false
  $script:targetTime = $null
  $btnSafeStop.Text = ("안전 중지(F9)" + [Environment]::NewLine + "(회차 완료 후)")
  Remove-Item -LiteralPath $safeStopFlag -Force -ErrorAction SilentlyContinue
  # 화면 유지 신호 해제 (평소 절전 설정으로 복귀)
  [Win32.PowerState]::SetThreadExecutionState($script:esRelease) | Out-Null
  if ($wasCustom) {
    # 커스텀 정지 상태줄: '완료: N바퀴 M항목(통산 K판)'. progress 는 '다음에 실행할' 위치이므로
    # 완료량 = (lap-1)바퀴 + index 항목. 완주 정지로 progress 가 지워졌으면 'N바퀴 완료' 표기.
    # 여기서는 progress 를 읽기만 하고 절대 쓰지 않습니다 (즉시 중지/강제 종료 = 진행 무변경 원칙).
    $doneText = "통산 $($script:completedCycles)판"
    try {
      $cfgStop = Read-Config
      $nodeStop = $null
       if ($cfgStop -and $cfgStop.PSObject.Properties[$script:customConfigSection]) { $nodeStop = $cfgStop.$script:customConfigSection }
      $progressStop = $null
      if ($nodeStop -and $nodeStop.PSObject.Properties['progress'] -and $nodeStop.progress) { $progressStop = $nodeStop.progress }
      if ($progressStop) {
        $lapDone = [int]$progressStop.lap - 1
        $itemDone = [int]$progressStop.index
        $doneText = "완료: ${lapDone}바퀴 ${itemDone}항목(통산 $($script:completedCycles)판)"
      } elseif ($nodeStop -and [string]$nodeStop.listRepeat -eq 'count' -and $script:completedCycles -gt 0) {
        $lapTarget = 1
        try { $lapTarget = [int]$nodeStop.listRepeatCount } catch { }
        $doneText = "${lapTarget}바퀴 완료(통산 $($script:completedCycles)판)"
      } else {
        $doneText = "완료: 0바퀴 0항목(통산 $($script:completedCycles)판)"
      }
    } catch { }
    $lblStatus.Text = "중지됨 - $Reason ($doneText)"
    # 커스텀 실행 컨텍스트/환경변수 정리 (다음 비커스텀 실행이 커스텀으로 오동작하는 사고 방지)
    Clear-CustomEnv
    $script:customActive = $false
  } else {
    $lblStatus.Text = "중지됨 - $Reason (완료: $($script:completedCycles)회)"
  }
  $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
  Add-GuiLog "중지: $Reason"
}

# --- 타이머: 워커 상태 + 로그 tail ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 600
$timer.Add_Tick({
    # 워커 로그 tail
    if ($script:running) {
      $lines = Read-NewLogLines -Path $workerLog -Offset ([ref]$script:logOffset)
      if ($null -ne $lines) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
          $displayLine = Convert-WorkerLogLineForGui -Line $lines[$i] -CustomActive $script:customActive
          if ($null -eq $displayLine) { continue }
          Add-ColoredLogLine ('  ' + $displayLine)
        }
      }
      # 기본 로그가 이미 잠긴 상태에서 시작했거나 쓰기 스트림에 장애가 생긴 경우 워커는
      # 복구 로그로 전환합니다. 기본 로그의 마지막 오프셋 이후 내용을 이어서 화면에 표시합니다.
      $recoveryLines = Read-NewLogLines -Path $workerRecoveryLog -Offset ([ref]$script:recoveryLogOffset)
      if ($null -ne $recoveryLines) {
        for ($i = 0; $i -lt $recoveryLines.Count; $i++) {
          $displayLine = Convert-WorkerLogLineForGui -Line $recoveryLines[$i] -CustomActive $script:customActive
          if ($null -eq $displayLine) { continue }
          Add-ColoredLogLine ('  ' + $displayLine)
        }
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
      $finishedWorker = $script:worker
      $exitCode = 1
      try { $exitCode = $finishedWorker.ExitCode }
      catch { Add-GuiLog "[오류] 워커 종료 코드를 읽지 못했습니다: $($_.Exception.Message)" }
      finally {
        try { $finishedWorker.Dispose() } catch { }
        $script:worker = $null
      }
      if ($exitCode -eq 0) {
        $script:preparedStreak = 0
        $script:completedCycles++
        $finishedContext = $null
        if ($script:customActive) {
          $finishedContext = Get-CustomCurrentContext
          # 복구 회차는 아래의 전용 성공 문구만 표시합니다. 정상 회차는 바퀴/항목 위치로 완료를 표시합니다.
          if (-not $script:customRecoveryPending) {
            if ($finishedContext) { Add-GuiLog "[커스텀] $($finishedContext.Position) 항목 완료" }
            else { Add-GuiLog "=== $($script:completedCycles)회차 완료 ===" }
          }
        } else {
          Add-GuiLog "=== $($script:completedCycles)회차 완료 ==="
        }
        if ($script:customActive) {
          # 커스텀 반복: 정상 판 또는 완료 후 마무리 복구가 코드 0에 도달한 시점에만 한 번 계상합니다.
          # 마커를 먼저 소비해 완주 정지/GUI 재시작에서도 같은 판을 다시 복구하지 않게 합니다.
          $wasRecovery = $script:customRecoveryPending
          $script:customErrorStreak = 0
          $script:customRestart = $false
          if ($finishedContext) { $script:customPrevItem = Format-CustomItemToken -Item $finishedContext.Item }
          $advanced = Step-CustomProgress
          if (-not $advanced) {
            # 완료 마커는 소비하지 않습니다. 다음 수동 시작에서 같은 소유 항목의 완료 사실을
            # 복구해 은동전 판을 다시 돌지 않게 합니다.
            $script:customRecoveryPending = $true
            $script:customRestart = $true
            Stop-AllRun '커스텀 진행 기록 저장 실패 - 중복 실행 방지를 위해 정지'
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            return
          }
          $script:customRecoveryPending = $false
          Remove-Item -LiteralPath $customMarkerFile -Force -ErrorAction SilentlyContinue
          if (Test-Path -LiteralPath $customMarkerFile) {
            # 삭제 실패 파일이 다음 수동 시작에서 유효 마커로 복구되지 않도록 소유자 형식을 무효화합니다.
            try { Set-Content -LiteralPath $customMarkerFile -Value '{}' -Encoding UTF8 -ErrorAction Stop } catch { }
          }
          if ($wasRecovery) {
            Add-GuiLog '[커스텀] 마무리 복구 완료 - 다음 항목으로 진행합니다.'
          }
          $lapComplete = $false
          if ($advanced -and $finishedContext) {
            # 완주 판정(GUI 담당): 전진 '후' lap 이 목표를 넘는 순간 (lap 은 1 시작 - N=1 이면 전진 후 lap 2)
            $lapComplete = Test-CustomLapComplete -ListRepeat $finishedContext.ListRepeat `
              -ListRepeatCount $finishedContext.ListRepeatCount -Lap ([int]$advanced.lap)
          }
          if ($script:stopRequested) {
            # 안전 중지도 판 완료(코드 0)이므로 전진을 먼저 마친 뒤 정지합니다
            Stop-AllRun '안전 중지'
          } elseif ($lapComplete) {
            # 완주 정지 시점에 진행 기록 자동 삭제 - 다음 시작은 새 1바퀴부터 (요청사항 확정 스펙)
            if (Reset-CustomProgress) {
              Stop-AllRun '지정 바퀴 완료'
            } else {
              # 전진된 lap>N 진행은 디스크에 남아 다음 시작 게이트가 다시 초기화를 시도합니다.
              Stop-AllRun '지정 바퀴 완료 후 진행 초기화 저장 실패'
              $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            }
          } else {
            Start-NextCycle
          }
        } else {
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
        }
      } elseif ($exitCode -eq 10) {
        # 준비 실행(화면 복귀만 수행, 던전 미실행): 회차로 세지 않고 곧바로 본 회차를 시작합니다.
        # 이렇게 해야 횟수 지정 모드에서 실제 던전 실행 횟수가 요청보다 적어지지 않습니다.
        $script:preparedStreak++
        Add-GuiLog '[안내] 화면 복귀(준비 실행)만 수행 - 회차로 세지 않고 이어서 시작합니다'
        if ($script:customActive) {
          # 커스텀: 전진 없음(미계상) - 같은 항목을 다시 실행합니다. 준비 실행이 화면을 옵션/선택
          # 화면까지 정리했으므로 PREV 를 비워 다음 회차가 '다시 하기' 경로 대신 선택 화면 절차를 밟게 함
          $script:customPrevItem = ''
          $script:customRestart = $false
        }
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
        if ($script:customActive -and -not $script:customMarkerIgnore -and (Test-Path -LiteralPath $customMarkerFile)) {
          # 커스텀 + 완료 마커: 클리어 확정(결과 화면 도달) 후 마무리 단계에서 조건 정지된 판이므로
          # 완료로 계상하고 전진한 '뒤' 정지합니다 (전진 없이 정지하면 다음 시작 때 같은 은동전 판을
          # 한 번 더 돌아 이중 소모 - 요청사항 확정 스펙)
          $script:completedCycles++
          $finishedContext = Get-CustomCurrentContext
          if ($finishedContext) { Add-GuiLog "[커스텀] $($finishedContext.Position) 항목 완료" }
          else { Add-GuiLog "=== $($script:completedCycles)회차 완료 ===" }
          if ($finishedContext) { $script:customPrevItem = Format-CustomItemToken -Item $finishedContext.Item }
          $stoppedProgress = Step-CustomProgress
          if (-not $stoppedProgress) {
            Stop-AllRun '조건 정지 판의 커스텀 진행 기록 저장 실패 - 완료 마커를 보존하고 정지'
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            return
          }
        }
        Stop-AllRun '조건 충족으로 정지 - 은동전 소진 등 (자세한 내용은 로그 참고)'
        $lblStatus.ForeColor = [System.Drawing.Color]::SteelBlue
      } else {
        if ($script:customActive -and $exitCode -eq 1) {
          # 커스텀 오류(코드 1): 완료 마커가 있으면 진행도를 먼저 넘기지 않고 같은 항목의 마무리만
          # 복구합니다. 복구 워커가 코드 0으로 끝난 뒤 위 정상 분기에서 딱 한 번 전진합니다.
          # 마커가 없으면 같은 항목 전체를 2회까지 자동 재시작합니다.
          $markerExists = ($script:customRecoveryPending -or
            ((-not $script:customMarkerIgnore) -and (Test-Path -LiteralPath $customMarkerFile)))
          $errorAction = Get-CustomErrorAction -MarkerExists $markerExists -ErrorStreak $script:customErrorStreak
          if ($errorAction -eq 'recover') {
            $script:customErrorStreak++
            $finishedContext = Get-CustomCurrentContext
            if ($finishedContext) { $script:customPrevItem = Format-CustomItemToken -Item $finishedContext.Item }
            $script:customRecoveryPending = $true
            $script:customRestart = $true
            if ($script:stopRequested) {
              Stop-AllRun '안전 중지'
            } else {
              Add-GuiLog '[커스텀] 이전 완료 항목의 마무리를 복구합니다.'
              Start-NextCycle
            }
          } elseif ($errorAction -eq 'retry') {
            $script:customErrorStreak++
            $script:customRecoveryPending = $false
            $script:customRestart = $true
            $script:customPrevItem = ''
            if ($script:stopRequested) {
              Stop-AllRun '안전 중지'
            } else {
              Add-GuiLog "[안내] 오류 종료(코드 1) - 같은 항목을 자동 재시작합니다 (재시도 $($script:customErrorStreak)/2)"
              Start-NextCycle
            }
          } else {
            Stop-AllRun '오류 종료(코드 1) - 같은 항목 3회 연속 실패 (로그 확인)'
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
          }
        } else {
          Stop-AllRun "오류 종료(코드 $exitCode) - 로그 확인"
          $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
      }
    }
  })

# --- 버튼 이벤트 ---
$btnStart.Add_Click({
    $isCustomStart = ($rbCustomRepeat.Checked -and -not $rbCatHunting.Checked)
    $script:customConfigSection = $(if ($rbCatAbyss.Checked) { 'abyssCustomRepeat' } else { 'customRepeat' })
    $script:customMarkerFile = $(if ($rbCatAbyss.Checked) { $customAbyssMarkerFile } else { $customDungeonMarkerFile })
    if ($rbCatDungeon.Checked) {
      if ($isCustomStart) {
        # 커스텀 반복 시작 안내 (한 번만 표시: 열어 둔 던전 하나 / 우연한 만남 강제)
        Add-GuiLog '[안내] 커스텀 반복: 시작 시 열어 둔 던전 하나에서 리스트 순서대로 동작합니다.'
        Add-GuiLog "[안내] '커스텀 반복'은 설정과 무관하게 '우연한 만남'으로 진행합니다."
      } else {
        # 시작 화면 요구사항 안내: 던전은 구역 선택 화면(또는 진입 옵션/결과 화면)에서 시작해야 합니다
        Add-GuiLog '[안내] 던전 자동화: 원하는 던전의 구역 선택 화면(또는 진입 옵션 화면)을 열어 두고 시작하세요. 은동전 옵션을 켰다면 실제로 은동전이 소모됩니다.'
      }
    }
    if ($rbCatAbyss.Checked -and $isCustomStart) {
      Add-GuiLog '[안내] 어비스 커스텀 반복: 리스트 순서대로 항목을 한 판씩 실행합니다.'
    }
    if (-not (Test-Path -LiteralPath $workerScript)) {
      [System.Windows.Forms.MessageBox]::Show('mabinogi_run_once.ps1 을 찾지 못했습니다.', '오류') | Out-Null
      return
    }
    if (-not (Save-SettingsFromUi)) { return }
    # ----- 커스텀 반복 시작 게이트: 빈 리스트 거부 / 이어가기 지문 검사 / 완주 취급 / 컨텍스트 초기화 -----
    $script:customActive = $isCustomStart
    if ($script:customActive) {
      $crCfg = Read-Config
      $crNode = $null
      if ($crCfg -and $crCfg.PSObject.Properties[$script:customConfigSection]) { $crNode = $crCfg.$script:customConfigSection }
      $crItems = @()
      if ($crNode -and $crNode.PSObject.Properties['items']) { $crItems = @($crNode.items) }
      if ($crItems.Count -eq 0) {
        # 빈 리스트는 시작하지 않고 로그로만 안내 (GUI 팝업 금지 규칙)
        Add-GuiLog '[안내] 커스텀 반복 리스트가 비어 있습니다 - [추가] 버튼으로 항목을 추가한 뒤 시작해 주세요.'
        $script:customActive = $false
        return
      }
      # 전환 규칙 게이트: 게임에서 불가능한 층 전환(2층→1층, 1-3 아닌 1층→2층)이 리스트에
      # 있으면 시작을 거부합니다 (워커 v4 전환 설계가 같은 층/1-3→2층만 처리 가능 - 실측 근거는
      # Get-CustomTransitionIssues 주석). Save-SettingsFromUi 직후라 config 값 = UI 값입니다.
      $crGateRepeat = 'infinite'; $crGateLaps = 1
      try { if ($crNode.PSObject.Properties['listRepeat']) { $crGateRepeat = [string]$crNode.listRepeat } } catch { }
      try { if ($crNode.PSObject.Properties['listRepeatCount']) { $crGateLaps = [int]$crNode.listRepeatCount } } catch { }
      $crGateIssues = @()
      if ($script:customConfigSection -eq 'customRepeat') {
        $crGateIssues = @(Get-CustomTransitionIssues -Items $crItems -ListRepeat $crGateRepeat -ListRepeatCount $crGateLaps)
      }
      # 어비스 방식·매칭 통일 게이트: GUI 에서는 라디오 잠금으로 섞일 수 없지만 config 를 직접
      # 편집하면 섞인 리스트가 들어올 수 있어 시작을 거부하고 어떤 항목이 다른지 로그로 알립니다
      # (무인 운용 보호 - 팝업 없이 로그만).
      if ($script:customConfigSection -eq 'abyssCustomRepeat') {
        $acrGateIssues = @(Get-AbyssMatchingIssues -Items $crItems)
        if ($acrGateIssues.Count -gt 0) {
          Add-GuiLog '[경고] 어비스 커스텀 반복: 리스트의 방식·매칭이 서로 달라 시작할 수 없습니다 - 리스트 전체가 같은 방식·매칭이어야 합니다.'
          foreach ($acrGateIssue in $acrGateIssues) {
            Add-GuiLog ('[경고] {0}번({1} 매칭 ''{2}''): {3}' -f $acrGateIssue.Index, $acrGateIssue.Mode, $acrGateIssue.Matching, $acrGateIssue.Reason)
          }
          Add-GuiLog '[안내] 리스트를 비우고 원하는 방식·매칭으로 다시 추가해 주세요.'
          $script:customActive = $false
          return
        }
      }
      if ($crGateIssues.Count -gt 0) {
        Add-GuiLog '[경고] 커스텀 반복: 게임에서 불가능한 층 전환이 리스트에 있어 시작할 수 없습니다 - 아래 항목의 순서를 조정해 주세요.'
        # 팝업 안내 (2026-07-20 사용자 확정): 시작 버튼 클릭 즉답 팝업 - 팝업 금지 규칙의
        # 명시적 예외 (실행 중엔 시작 버튼이 숨겨져 있어 무인 운용을 막지 않음. CLAUDE.md 참고).
        # 위반이 많으면 앞 5건까지만 팝업에 담고 나머지는 로그로 확인하게 합니다.
        $crGateLines = @()
        $crGateWrapSeen = $false
        foreach ($crGateIssue in $crGateIssues) {
          $crGateWrapTag = $(if ([bool]$crGateIssue.Wrap) { ' [바퀴 순환: 마지막 → 첫 항목]' } else { '' })
          Add-GuiLog ('[경고] {0} → {1}{2}: {3}' -f $crGateIssue.From, $crGateIssue.To, $crGateWrapTag, $crGateIssue.Reason)
          if ([bool]$crGateIssue.Wrap) {
            $crGateWrapSeen = $true
            Add-GuiLog "[경고] 층이 섞인 혼합 리스트는 1바퀴 전용입니다 - 리스트 반복을 '횟수 1바퀴'로 바꿔 주세요."
          }
          if ($crGateLines.Count -lt 5) {
            $crGateLines += ('- {0} → {1}{2}' -f $crGateIssue.From, $crGateIssue.To, $crGateWrapTag)
            $crGateLines += ('  {0}' -f [string]$crGateIssue.Reason)
          }
        }
        $crGateText = "시작할 수 없습니다 - 게임에서 불가능한 층 전환이 리스트에 있습니다.`n`n" +
          ($crGateLines -join "`n")
        if ($crGateIssues.Count -gt 5) { $crGateText += "`n... 외 $($crGateIssues.Count - 5)건 (로그 참고)" }
        if ($crGateWrapSeen) {
          $crGateText += "`n`n층이 섞인 혼합 리스트는 1바퀴 전용입니다.`n리스트 반복을 '횟수 1바퀴'로 바꿔 주세요."
        } else {
          $crGateText += "`n`n항목의 순서를 조정한 뒤 다시 시작해 주세요."
        }
        [System.Windows.Forms.MessageBox]::Show($crGateText, '커스텀 반복 - 시작 불가',
          [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $script:customActive = $false
        return
      }
      $crProgress = $null
      if ($crNode.PSObject.Properties['progress'] -and $crNode.progress) { $crProgress = $crNode.progress }
      if ($crProgress) {
        # 이어가기 안전장치: 리스트가 하나라도 바뀌었으면(지문 불일치) 무조건 처음부터 (요청사항 확정)
        $savedFingerprint = ''
        try { $savedFingerprint = [string]$crProgress.fingerprint } catch { }
        if ($savedFingerprint -ne (Get-CustomFingerprint -Items $crItems)) {
          if (-not (Reset-CustomProgress -LogMessage '[안내] 커스텀 반복: 리스트 변경 - 처음부터 시작합니다.')) {
            Add-GuiLog '[오류] 변경된 리스트의 진행 기록을 초기화하지 못해 시작하지 않습니다.'
            $script:customActive = $false
            return
          }
          $crProgress = $null
        }
      }
      if ($crProgress) {
        # 무한으로 돌다 N바퀴로 줄인 경우 등: 저장된 lap 이 이미 목표를 넘었으면 완주 취급 후 새 1바퀴
        $crListRepeat = 'infinite'; $crLapTarget = 1; $crLapNow = 1; $crIndexNow = 0
        try { if ($crNode.PSObject.Properties['listRepeat']) { $crListRepeat = [string]$crNode.listRepeat } } catch { }
        try { if ($crNode.PSObject.Properties['listRepeatCount']) { $crLapTarget = [int]$crNode.listRepeatCount } } catch { }
        try { $crLapNow = [int]$crProgress.lap } catch { }
        try { $crIndexNow = [int]$crProgress.index } catch { }
        if (Test-CustomLapComplete -ListRepeat $crListRepeat -ListRepeatCount $crLapTarget -Lap $crLapNow) {
          if (-not (Reset-CustomProgress -LogMessage '[안내] 커스텀 반복: 저장된 진행이 지정 바퀴를 이미 완주한 상태 - 새 1바퀴부터 시작합니다.')) {
            Add-GuiLog '[오류] 완주된 진행 기록을 초기화하지 못해 시작하지 않습니다.'
            $script:customActive = $false
            return
          }
        } else {
          Add-GuiLog "[안내] 커스텀 반복: 저장된 진행을 이어갑니다 - $(Get-CustomPositionText -Lap $crLapNow -Index $crIndexNow -Total $crItems.Count)부터 시작합니다."
        }
      }
      $script:customErrorStreak = 0
      $script:customPrevItem = ''
      $script:customRestart = $false
      $script:customRecoveryPending = $false
    }
    $cleanup = Stop-ExistingAutomation
    if ($cleanup.Killed -gt 0) {
      Add-GuiLog "기존 자동화 프로세스 $($cleanup.Killed)개를 종료했습니다."
      # 강제 종료된 워커가 키/마우스 '누름-뗌' 사이였을 수 있으므로 입력 상태를 정리합니다
      Release-StuckInput
    }
    if ($cleanup.Failed -gt 0) { Add-GuiLog "[경고] 기존 자동화 프로세스 $($cleanup.Failed)개를 종료하지 못했습니다 - 새 회차가 '중복 실행'으로 멈추면 작업 관리자에서 powershell.exe 를 직접 종료해 주세요." }
    if ($script:customActive -and (Test-Path -LiteralPath $customMarkerFile)) {
      # GUI/워커가 클리어 뒤 마무리 중 종료됐어도 구조화 마커의 소유자가 현재 progress 와
      # 정확히 같으면 그 항목을 다시 입장하지 않고 마무리 복구부터 이어갑니다.
      $resumeContext = Get-CustomCurrentContext
      $markerOwner = Read-CustomMarkerOwner
      if (Test-CustomMarkerOwnerMatchesContext -Owner $markerOwner -Context $resumeContext) {
        $script:customRecoveryPending = $true
        $script:customRestart = $true
        $script:customPrevItem = Format-CustomItemToken -Item $resumeContext.Item
        Add-GuiLog '[커스텀] 이전 완료 항목의 마무리를 복구합니다.'
      } else {
        # 구버전 타임스탬프/부분 파일/다른 리스트·위치의 마커는 오계상 방지를 위해 폐기합니다.
        Remove-Item -LiteralPath $customMarkerFile -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $customMarkerFile) {
          Add-GuiLog '[경고] 현재 진행 위치와 맞지 않는 완료 마커를 삭제하지 못했습니다 - 이번 회차는 마커를 무시합니다.'
          $script:customMarkerIgnore = $true
        } else {
          Add-GuiLog '[안내] 현재 진행 위치와 맞지 않는 이전 완료 마커를 정리했습니다.'
        }
      }
    }
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
    # 커스텀 반복은 상단 횟수/시간과 택일 관계 - 라디오가 비활성이라 실질 방어용 강제 해제
    if ($script:customActive) { $script:targetCycles = 0; $script:targetTime = $null }
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
      if ($script:customActive) {
        # 커스텀 반복은 회차 번호 대신 진행 위치로 표기합니다
        $positionNow = ''
        try {
          $contextNow = Get-CustomCurrentContext
          if ($contextNow) { $positionNow = $contextNow.Position }
        } catch { }
        $lblStatus.Text = "커스텀: $positionNow 실행 중 (안전 중지 취소됨)"
      } else {
        $statusSuffix = ''
        if ($null -ne $script:targetTime) { $statusSuffix = " ($($script:targetTime.ToString('HH:mm')) 까지)" }
        $lblStatus.Text = "$($script:completedCycles + 1)회차 실행 중...$statusSuffix (안전 중지 취소됨)"
      }
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
      $closingWorker = $script:worker
      if ($closingWorker) {
        $closingWorkerWasKilled = $false
        try {
          if (-not $closingWorker.HasExited) {
            $closingWorker.Kill()
            $closingWorker.WaitForExit()
            $closingWorkerWasKilled = $true
          }
        } catch { }
        finally {
          try { $closingWorker.Dispose() } catch { }
          $script:worker = $null
        }
        if ($closingWorkerWasKilled) { Release-StuckInput }
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
  # 커스텀 반복 라디오는 던전/어비스에서 활성화합니다. 사냥터로는 전환할 수 없고
  # 선택 의도는 config 에 보존합니다.
  # crSwitching 가드: 이 프로그램적 전환이 라디오 CheckedChanged 의 enabled 저장을 오염시키지 않게 함
  $supportsCustom = -not $isHunting
  $rbCustomRepeat.Enabled = $supportsCustom
  if (-not $supportsCustom) {
    if ($rbCustomRepeat.Checked) {
      $script:crSwitching = $true
      try { $rbInfinite.Checked = $true } finally { $script:crSwitching = $false }
    }
  } elseif ($script:customEnabledWish -and -not $rbCustomRepeat.Checked) {
    $script:crSwitching = $true
    try { $rbCustomRepeat.Checked = $true } finally { $script:crSwitching = $false }
  }
  $isCustom = $supportsCustom -and $rbCustomRepeat.Checked
  $isDungeonCustom = $isDungeon -and $isCustom
  $isAbyssCustom = $isAbyss -and $isCustom
  $grpContentDetail.Text = '콘텐츠 상세 설정'
  # 커스텀 반복 중에는 사냥터 카테고리로 전환하지 못하게 합니다.
  # 커스텀 반복을 해제하거나 다른 카테고리로 폴백하면 문구와 활성 상태가 즉시 원래대로 돌아옵니다.
  $rbCatHunting.Text = $(if ($isCustom) { '사냥터(미지원)' } else { '사냥터' })
  $rbCatHunting.Enabled = -not $isCustom
  # 어비스용 패널 (함께하기일 때만 매칭 줄이 난이도 아래에 나타나고 던전 목록이 내려감)
  # 파티(파티원)은 난이도/던전 선택이 의미가 없어(파티장이 결정) 두 줄을 숨기고
  # 매칭 줄을 난이도 자리로 올립니다.
  $abyssSingleOn = $isAbyss -and -not $isAbyssCustom
  $abyssPartyOn = $abyssSingleOn -and $rbModeParty.Checked
  $abyssMemberOn = $abyssPartyOn -and $rbAbyssPartyMember.Checked
  $pnlMode.Visible = $abyssSingleOn
  $pnlDifficulty.Visible = $abyssSingleOn -and -not $abyssMemberOn
  $pnlAbyssMatching.Visible = $abyssPartyOn
  $pnlAbyssMatching.Top = $(if ($abyssMemberOn) { 52 } else { 84 })
  $pnlDungeon.Visible = $abyssSingleOn -and -not $abyssMemberOn
  $pnlDungeon.Top = $(if ($abyssPartyOn) { 116 } else { 84 })
  # 던전용 패널 (더블 루팅은 은동전 사용 체크박스 옆, 2단계 소진 대응은 해당 조건에서만 표시.
  # 커스텀 반복 선택 시 단일 모드 줄들은 전부 숨기고 리스트 빌더로 전환합니다)
  $ndSingleOn = $isDungeon -and -not $isDungeonCustom
  $coinRowOn = $ndSingleOn -and $chkNdCoin.Checked
  $ndNoDoubleRowOn = $coinRowOn -and $chkNdDoubleLoot.Checked
  $pnlNdDifficulty.Visible = $ndSingleOn
  $pnlNdStage.Visible = $ndSingleOn
  $pnlNdCoin.Visible = $ndSingleOn
  $pnlNdExhaust.Visible = $coinRowOn
  $pnlNdNoDouble.Visible = $ndNoDoubleRowOn
  $pnlNdParty.Visible = $ndSingleOn
  # 커스텀 반복 리스트 빌더 패널 (던전 + 커스텀 반복 선택 시에만 표시.
  # 소진/더블 불가 라디오 줄은 입력 줄의 은동전/더블 루팅 체크 상태를 따라갑니다)
  $crExhaustRowOn = $isDungeonCustom -and $chkCrCoin.Checked
  $crNoDoubleRowOn = $crExhaustRowOn -and $chkCrDouble.Checked
  $pnlCrInput.Visible = $isDungeonCustom
  $pnlCrExhaust.Visible = $crExhaustRowOn
  $pnlCrNoDouble.Visible = $crNoDoubleRowOn
  $lvCrList.Visible = $isDungeonCustom
  $btnCrAdd.Visible = $isDungeonCustom
  $btnCrDelete.Visible = $isDungeonCustom
  $btnCrUp.Visible = $isDungeonCustom
  $btnCrDown.Visible = $isDungeonCustom
  $pnlCrRepeat.Visible = $isDungeonCustom
  # 어비스 커스텀: 함께하기일 때만 입력 줄 바로 아래에 매칭 줄을 추가합니다.
  $acrPartyOn = $isAbyssCustom -and $rbAcrParty.Checked
  $pnlAcrInput.Visible = $isAbyssCustom
  $pnlAcrMatching.Visible = $acrPartyOn
  $lvAcrList.Visible = $isAbyssCustom
  $btnAcrAdd.Visible = $isAbyssCustom
  $btnAcrDelete.Visible = $isAbyssCustom
  $btnAcrUp.Visible = $isAbyssCustom
  $btnAcrDown.Visible = $isAbyssCustom
  $pnlAcrRepeat.Visible = $isAbyssCustom
  # 사냥터용 패널 (소진 대응 옵션 없음 - 은동전이 부족하면 나가고 자동화 종료)
  $pnlHtDifficulty.Visible = $isHunting
  $pnlHtCoin.Visible = $isHunting
  $pnlHtParty.Visible = $isHunting
  # 줄 수에 맞춰 배치/그룹 높이를 조절하고 아래 요소들을 내리거나 올립니다
  # (어비스/사냥터 3줄 = 122 / 어비스 함께하기·던전 4줄 = 150 /
  #  던전 + 소진 대응 5줄 = 182 / 더블 불가 대응까지 6줄 = 208 /
  #  던전 커스텀 반복 = 입력 줄 + 라디오 줄 0~2개 + 리스트 + 리스트 반복 줄: 라디오 줄 수에
  #  따라 리스트/버튼 열/하단 줄을 내리고 그룹 높이를 244~296 으로 재계산)
  if ($isDungeon) {
    if ($isDungeonCustom) {
      $crRowTop = 50
      if ($crExhaustRowOn) { $pnlCrExhaust.Top = $crRowTop; $crRowTop += 26 }
      if ($crNoDoubleRowOn) { $pnlCrNoDouble.Top = $crRowTop; $crRowTop += 26 }
      $crListTop = $crRowTop + 2
      $lvCrList.Top = $crListTop
      $btnCrAdd.Top = $crListTop
      $btnCrDelete.Top = $crListTop + 36
      $btnCrUp.Top = $crListTop + 72
      $btnCrDown.Top = $crListTop + 108
      $pnlCrRepeat.Top = $crListTop + 156
      $grpContentDetail.Height = $pnlCrRepeat.Top + 36
    } elseif ($ndNoDoubleRowOn) {
      $pnlNdParty.Top = 174
      $grpContentDetail.Height = 208
    } elseif ($coinRowOn) {
      $pnlNdParty.Top = 148
      $grpContentDetail.Height = 182
    } else {
      $pnlNdParty.Top = 116
      $grpContentDetail.Height = 150
    }
  } elseif ($isAbyssCustom) {
    $acrListTop = $(if ($acrPartyOn) { 78 } else { 52 })
    $lvAcrList.Top = $acrListTop
    $btnAcrAdd.Top = $acrListTop
    $btnAcrDelete.Top = $acrListTop + 36
    $btnAcrUp.Top = $acrListTop + 72
    $btnAcrDown.Top = $acrListTop + 108
    $pnlAcrRepeat.Top = $acrListTop + 156
    $grpContentDetail.Height = $pnlAcrRepeat.Top + 36
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
  # 어비스 커스텀 방식·매칭 입력 잠금 재적용 (여기서 라디오가 바뀌면 CheckedChanged 로 이 블록이
  # 한 번 더 돌아 배치가 다시 맞춰집니다 - 잠금 함수 쪽 재진입 가드로 무한 재귀는 없습니다)
  Update-AbyssInputLock
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
Add-GuiLog '컨트롤 패널이 준비됐습니다. [시작]을 누르면 반복을 시작합니다.'
if ($script:configMigrated) {
  Add-GuiLog '[안내] 업데이트 감지: 설정을 새 버전 형식으로 이전했습니다 (사용자 설정은 유지, 화면 좌표는 최신으로 갱신)'
  if ($script:customProgressReset) {
    Add-GuiLog '[안내] 업데이트로 커스텀 반복 진행 기록을 초기화했습니다 (리스트는 유지 - 다음 시작은 처음부터)'
  }
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
$lnkUpdate.LinkColor = $script:themeTitle          # 새 버전 링크도 꿀 갈색으로

# ============================================================
#  최신 버전 확인 (GitHub 릴리스, 시작 시 1회)
# ============================================================
# 백그라운드 러닝스페이스에서 확인하므로 GUI가 멈추지 않고, 실패(오프라인/비공개
# 저장소/요청 한도)는 조용히 무시하고 정상 시작합니다. 새 버전이 있으면 우하단
# 버전 표시가 다운로드 링크로 바뀝니다. 무인 운용을 방해하지 않도록 팝업은
# 절대 띄우지 않습니다.
$script:updateCheckPs = [System.Management.Automation.PowerShell]::Create()
[void]$script:updateCheckPs.AddScript({
    try {
      # PS 5.1 기본 설정에는 TLS 1.2가 빠져 있을 수 있어 추가합니다 (3072 = Tls12)
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
      # User-Agent 헤더가 없으면 GitHub API가 요청을 거부합니다
      $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Myodong/HoneyNogi/releases/latest' `
        -Headers @{ 'User-Agent' = 'HoneyNogi-UpdateCheck' } -TimeoutSec 5
      return [string]$release.tag_name
    } catch { return '' }
  })
$script:updateCheckAsync = $script:updateCheckPs.BeginInvoke()
$script:updateTimer = New-Object System.Windows.Forms.Timer
$script:updateTimer.Interval = 1000
$script:updateTimer.Add_Tick({
    if (-not $script:updateCheckAsync.IsCompleted) { return }
    $script:updateTimer.Stop()
    $tag = ''
    try {
      $checkResult = $script:updateCheckPs.EndInvoke($script:updateCheckAsync)
      if ($checkResult -and $checkResult.Count -gt 0) { $tag = [string]$checkResult[0] }
    } catch { }
    try { $script:updateCheckPs.Dispose() } catch { }
    $remoteVersion = $null
    if (-not [System.Version]::TryParse(($tag -replace '^[vV]', ''), [ref]$remoteVersion)) { return }
    if ($remoteVersion -le [System.Version]$appVersion) { return }
    $lblVersion.Visible = $false
    $lnkUpdate.Text = "새 버전 v$remoteVersion 다운로드"
    $lnkUpdate.Visible = $true
    # 구버전 실행 시 새 버전 안내 팝업 (확인 1번 = 안내만, 자동 동작 없음).
    # 자동화가 이미 실행 중이면 팝업으로 방해하지 않고 우하단 링크만 보여줍니다.
    if (-not $script:running) {
      [System.Windows.Forms.MessageBox]::Show(
        $form,
        ("새 버전 v$remoteVersion 이 나왔습니다!" + [Environment]::NewLine + [Environment]::NewLine +
          "우측 하단의 '새 버전 다운로드' 링크를 누르면" + [Environment]::NewLine +
          "다운로드 페이지가 열립니다."),
        '꿀비노기 업데이트 안내',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
  })
$script:updateTimer.Start()

[void]$form.ShowDialog()
$hotkeyTimer.Stop()
$timer.Stop()
