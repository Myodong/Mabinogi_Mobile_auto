# 실패해도 진행하는 '확인 경고'(게임 전면화·커서 이동)의 반복 억제 판정을 검사합니다.
# 클릭마다 호출되는 확인이라, 연속 실패 중에 같은 경고가 로그를 도배하던 문제
# (2026-07-22 어비스 실주행 실측)를 막기 위한 규칙입니다.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'source_test_helpers.ps1')
$root = Split-Path -Parent $PSScriptRoot
$workerPath = Join-Path $root 'mabinogi_run_once.ps1'
Invoke-Expression ((Get-SourceFunctionDefinitions -Path $workerPath -Names @('Get-RepeatWarnAction')) -join "`n")

$fails = 0
function Check-Equal {
  param([string]$Name, $Actual, $Expected)
  if ($Actual -eq $Expected) { "OK   $Name" }
  else { "FAIL $Name (actual=$Actual expected=$Expected)"; $script:fails++ }
}

# --- 진리표: (이미 경고했는가) x (이번에 실패했는가) ---
Check-Equal '첫 실패 → 경고' (Get-RepeatWarnAction -WasWarned $false -Failed $true) 'warn'
Check-Equal '연속 실패 → 기록 없음' (Get-RepeatWarnAction -WasWarned $true -Failed $true) 'none'
Check-Equal '경고 후 성공 → 회복 안내' (Get-RepeatWarnAction -WasWarned $true -Failed $false) 'recover'
Check-Equal '정상 유지 → 기록 없음' (Get-RepeatWarnAction -WasWarned $false -Failed $false) 'none'

# --- 시퀀스 검증: 실패가 이어져도 경고는 1회, 회복도 1회만 나와야 합니다 ---
# 실제 호출부와 같은 상태 전이를 모사합니다 (warn 시 활성화, recover 시 해제).
function Invoke-WarnSequence {
  param([bool[]]$FailSequence)
  $warned = $false
  $emitted = @()
  foreach ($failed in $FailSequence) {
    $action = Get-RepeatWarnAction -WasWarned $warned -Failed $failed
    if ($action -eq 'warn') { $warned = $true; $emitted += 'W' }
    elseif ($action -eq 'recover') { $warned = $false; $emitted += 'R' }
  }
  return ($emitted -join '')
}

Check-Equal '실패 5연속 → 경고 1회만' (Invoke-WarnSequence -FailSequence @($true, $true, $true, $true, $true)) 'W'
Check-Equal '실패 3회 후 성공 → W 다음 R' (Invoke-WarnSequence -FailSequence @($true, $true, $true, $false)) 'WR'
Check-Equal '실패-성공 반복 → 전이마다 1회' (Invoke-WarnSequence -FailSequence @($true, $false, $true, $false)) 'WRWR'
Check-Equal '전부 성공 → 기록 없음' (Invoke-WarnSequence -FailSequence @($false, $false, $false)) ''
Check-Equal '성공 후 실패 → 경고 1회' (Invoke-WarnSequence -FailSequence @($false, $true, $true)) 'W'
# 회복 안내 뒤 다시 실패하면 새 연속 구간이므로 경고가 다시 나와야 합니다
Check-Equal '회복 후 재실패 → 경고 재발행' (Invoke-WarnSequence -FailSequence @($true, $false, $true, $true, $true)) 'WRW'

# --- 호출부 계약: 두 확인(전면화·커서)이 서로 다른 상태 변수를 쓰는지 소스로 확인 ---
$workerText = Get-Content -LiteralPath $workerPath -Raw
foreach ($stateVar in @('focusWarnActive', 'focusWarnSuppressed', 'cursorWarnActive', 'cursorWarnSuppressed')) {
  Check-Equal "상태 변수 선언: $stateVar" ($workerText -match ('\$script:{0}\s*=' -f $stateVar)) $true
}
# 억제 중에는 생략 횟수를 세고, 회복 안내에서 그 횟수를 알려야 진단 정보가 남습니다
Check-Equal '전면화: 회복 안내에 생략 횟수 포함' ($workerText -match '전면화 확인이 정상으로 돌아왔습니다[^"]*focusWarnSuppressed') $true
Check-Equal '커서: 회복 안내에 생략 횟수 포함' ($workerText -match '커서 위치 확인이 정상으로 돌아왔습니다[^"]*cursorWarnSuppressed') $true

exit $fails
