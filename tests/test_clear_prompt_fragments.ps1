# 클리어 문구('화면을 터치해 주세요') 감지 판정 진리표
# 본체: mabinogi_run_once.ps1 Test-DungeonClearPrompt (조각 조합 - 실측 깨짐 사례 기반)
$fails = 0
$cases = @(
  @{ T = '화면을터치해주세요'; E = $true },   # 정상
  @{ T = '화면을터夫6주'; E = $true },        # 2026-07-16: '치' 깨짐
  @{ T = '화n을터치해주l요'; E = $true },     # 2026-07-17: '면' 깨짐
  @{ T = '화면을치해주세요'; E = $true },     # 2026-07-18: '터' 통째 소실
  @{ T = '나가기'; E = $false },
  @{ T = '보상을확인해주세요'; E = $false },
  @{ T = '잠시만기다려주세요'; E = $false },
  @{ T = ''; E = $false }
)
foreach ($c in $cases) {
  $n = $c.T
  $hit = ($n.Contains('화면을') -and $n.Contains('터')) -or
         ($n.Contains('화면을') -and $n.Contains('주세요')) -or
         $n.Contains('터치해') -or $n.Contains('터치하')
  if ($hit -eq $c.E) { "OK  '{0}' -> {1}" -f $c.T, $hit }
  else { "FAIL '{0}' -> {1} (기대 {2})" -f $c.T, $hit, $c.E; $fails++ }
}
exit $fails
