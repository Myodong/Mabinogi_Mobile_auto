# 은동전 미사용 역방향 해제 루프(상태 기반) 시나리오 진리표
# 본체: mabinogi_run_once.ps1 던전/사냥터 역방향 검증 블록 (2026-07-19)
$fails = 0

function Test-Loop {
  param([string]$Name, [object[]]$Reads, [bool[]]$Failing, [string]$Expect)
  # $Reads[0] = 트리거 판독값(항상 10/20), 이후 = 재판독 순서. $Failing = 각 판독 시점의 캡처 실패 여부.
  $script:idx = 0
  $script:clicksSent = 0
  function Read-Next { $script:idx++; if ($script:idx -lt $Reads.Count) { return $Reads[$script:idx] } return $null }
  $offCost = $Reads[0]
  $offCleared = $false
  $offClicks = 0
  for ($offTry = 1; $offTry -le 5; $offTry++) {
    $failNow = if (($script:idx) -lt $Failing.Count) { $Failing[$script:idx] } else { $false }
    if ($null -eq $offCost) {
      if (-not $failNow) { $offCleared = $true; break }
    } elseif ($offCost -eq 10 -or $offCost -eq 20) {
      if ($offClicks -ge 2) { break }
      $offClicks++
      $script:clicksSent++
    } else { break }
    $offCost = Read-Next
  }
  $outcome = if ($offCleared) { '해제확인' }
  elseif ($null -ne $offCost -and ($offCost -eq 10 -or $offCost -eq 20)) { 'throw' }
  else { '경고후진행' }
  $desc = "{0} (클릭 {1}회)" -f $outcome, $script:clicksSent
  if ($desc -eq $Expect) { "OK  {0}: {1}" -f $Name, $desc }
  else { "FAIL {0}: {1} (기대 {2})" -f $Name, $desc, $Expect; $script:fails++ }
}

Test-Loop '정상 해제' @(10, $null) @($false, $false) '해제확인 (클릭 1회)'
Test-Loop '1클릭 무시 후 2회째 해제' @(10, 10, $null) @($false, $false, $false) '해제확인 (클릭 2회)'
Test-Loop '카드 안 꺼짐' @(10, 10, 10) @($false, $false, $false) 'throw (클릭 2회)'
Test-Loop '해제 후 잡음 숫자' @(10, 3) @($false, $false) '경고후진행 (클릭 1회)'
Test-Loop '캡처 실패 후 해제' @(10, $null, $null) @($false, $true, $false) '해제확인 (클릭 1회)'
Test-Loop '캡처 실패 지속' @(10, $null, $null, $null, $null) @($false, $true, $true, $true, $true) '경고후진행 (클릭 1회)'
Test-Loop '더블 루팅 20 해제' @(20, $null) @($false, $false) '해제확인 (클릭 1회)'
exit $fails
