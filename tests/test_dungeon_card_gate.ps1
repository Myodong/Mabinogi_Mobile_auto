# 좌표 버전 게이트의 어비스 카드(profiles.card) 보강 판정 진리표 (2026-07-19 개선점 (2))
# 본체: mabinogi_run_once.ps1 - 게이트 발동 시 profiles.<던전>.card 대신 내장 카드 좌표 사용
$fails = 0
$builtinDungeonCards = @{
  '허상의 정박지' = @(956, 157)
  '광기의 동굴'   = @(956, 272)
  '흩어진 물길'   = @(956, 387)
}
$ptAbyssCardDefault = @(956, 157)

function Resolve-Card {
  param([bool]$Stale, [string]$Selected, $ProfileCard)
  # 본체 해석 로직 사본: 프로파일 card → (게이트 발동 + 내장 목록 보유 시) 내장값으로 대체
  $card = $ptAbyssCardDefault
  if ($null -ne $ProfileCard) { $card = @($ProfileCard) }
  if ($Stale -and $builtinDungeonCards.ContainsKey($Selected)) {
    $card = @($builtinDungeonCards[$Selected])
  }
  return $card
}

$cases = @(
  @{ Name = '최신 config + 프로파일'; Stale = $false; Sel = '광기의 동굴'; Card = @(956, 272); E = @(956, 272) }
  @{ Name = '구버전 + 옛 카드 좌표';  Stale = $true;  Sel = '광기의 동굴'; Card = @(800, 500); E = @(956, 272) }  # 핵심: 옛 좌표 무시
  @{ Name = '구버전 + 카드 없음';     Stale = $true;  Sel = '흩어진 물길'; Card = $null;       E = @(956, 387) }
  @{ Name = '구버전 + 모르는 던전';   Stale = $true;  Sel = '신규 던전';   Card = @(700, 300); E = @(700, 300) }  # 대체값 없음 - 프로파일 유지(한계 명시)
  @{ Name = '최신 + 프로파일 없음';   Stale = $false; Sel = '허상의 정박지'; Card = $null;     E = @(956, 157) }
)
foreach ($c in $cases) {
  $r = Resolve-Card -Stale $c.Stale -Selected $c.Sel -ProfileCard $c.Card
  $ok = ($r.Count -eq 2 -and $r[0] -eq $c.E[0] -and $r[1] -eq $c.E[1])
  if ($ok) { "OK  {0}: ({1},{2})" -f $c.Name, $r[0], $r[1] }
  else { "FAIL {0}: ({1},{2}) (기대 {3},{4})" -f $c.Name, $r[0], $r[1], $c.E[0], $c.E[1]; $fails++ }
}
exit $fails
