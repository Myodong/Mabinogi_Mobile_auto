# 던전 시작 0-1단계(진입 옵션 화면 스테이지 검증) 판정 진리표 - 설정 1-3 기준
# 본체: mabinogi_run_once.ps1 Invoke-NormalDungeonCycle 0-1단계
$fails = 0
$stageFloor = '1'; $stageArea = '3'

$cases = @(
  @{ T = '1층3구역';  E = '일치(진행)' }      # 정상 복귀 회차
  @{ T = '2층3구역';  E = '불일치(되돌림)' }  # 2026-07-18 실측 사고 케이스
  @{ T = '2증3구역';  E = '불일치(되돌림)' }  # 층 깨짐 + 다른 층
  @{ T = '1츰3구역';  E = '일치(진행)' }      # 층 깨짐 + 같은 스테이지
  @{ T = '23구역';    E = '불일치(되돌림)' }  # 층 소실 + 다른 층 ({0,2} 완화로 감지)
  @{ T = '13구역';    E = '일치(진행)' }      # 층 소실 + 같은 스테이지
  @{ T = '153구역';   E = '불일치(되돌림)' }  # 층이 숫자로 깨짐 - 되돌려도 재선택이라 무해
  @{ T = 'l층3구역';  E = '불명확(진행)' }    # 숫자 판독 불가
  @{ T = '';          E = '캡처실패(첫 판정 유지)' }
  @{ T = '글라스기브넨던전'; E = '옵션화면아님' }
)
foreach ($c in $cases) {
  $titleText = $c.T
  $onOptions = $titleText.Contains('구역')
  if (-not $onOptions) {
    $verdict = if ($titleText.Length -eq 0) { '캡처실패(첫 판정 유지)' } else { '옵션화면아님' }
  } elseif ($titleText -notmatch "${stageFloor}\D{1,2}${stageArea}구역") {
    if ($titleText -match "(\d)\D{0,2}(\d)구역") {
      if (($Matches[1] -eq $stageFloor) -and ($Matches[2] -eq $stageArea)) { $verdict = '일치(진행)' }
      else { $verdict = '불일치(되돌림)' }
    } else { $verdict = '불명확(진행)' }
  } else { $verdict = '일치(진행)' }
  if ($verdict -eq $c.E) { "OK  '{0}' -> {1}" -f $c.T, $verdict }
  else { "FAIL '{0}' -> {1} (기대 {2})" -f $c.T, $verdict, $c.E; $fails++ }
}

# 선택 화면 복귀 성공 판정 ('구역' 없고 '던전'/'오드' 있음)
$backCases = @(
  @{ T = '글라스기브넨던전'; E = $true }
  @{ T = '바리오드'; E = $true }
  @{ T = '1층3구역'; E = $false }
  @{ T = ''; E = $false }
)
foreach ($c in $backCases) {
  $t = $c.T
  $backOk = (-not $t.Contains('구역')) -and ($t.Contains('던전') -or $t.Contains('오드'))
  if ($backOk -eq $c.E) { "OK  복귀판정 '{0}' -> {1}" -f $c.T, $backOk }
  else { "FAIL 복귀판정 '{0}' -> {1} (기대 {2})" -f $c.T, $backOk, $c.E; $fails++ }
}
exit $fails
