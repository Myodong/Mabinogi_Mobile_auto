# 클리어 문구('화면을 터치해 주세요') 감지 판정 진리표
# 본체: mabinogi_run_once.ps1 Test-DungeonClearPrompt (조각 조합 - 실측 깨짐 사례 기반)
$fails = 0
$cases = @(
  @{ T = '화면을터치해주세요'; E = $true },   # 정상
  @{ T = '화면을터夫6주'; E = $true },        # 2026-07-16: '치' 깨짐
  @{ T = '화n을터치해주l요'; E = $true },     # 2026-07-17: '면' 깨짐
  @{ T = '화면을치해주세요'; E = $true },     # 2026-07-18: '터' 통째 소실
  @{ T = '면百치해'; E = $true },             # 2026-07-19: '화'·'터'·'주세요' 소실 (캐릭터 겹침, 진단 판독)
  @{ T = '화면치6H天서j“'; E = $true },       # 2026-07-19: 같은 화면의 다른 깨짐 (재현 판독)
  @{ T = '화면을지해주세요'; E = $true },     # 2026-07-19: '터'→'지' (수동 검증 캡처, 던전 소탕)
  @{ T = '면을터치해주세요'; E = $true },     # 2026-07-19: '화' 소실 (수동 검증 캡처, 어비스)
  @{ T = '나가기'; E = $false },
  @{ T = '보상을확인해주세요'; E = $false },
  @{ T = '잠시만기다려주세요'; E = $false },
  @{ T = '경험치고二'; E = $false },          # 비대상 실측 판독 (00:21 하단 문구)
  @{ T = ''; E = $false }
)
foreach ($c in $cases) {
  $n = $c.T
  $hit = ($n.Contains('화면을') -and $n.Contains('터')) -or
         ($n.Contains('화면을') -and $n.Contains('주세요')) -or
         ($n.Contains('치해') -and $n.Contains('면')) -or
         ($n.Contains('화면') -and $n.Contains('치')) -or
         $n.Contains('터치해') -or $n.Contains('터치하')
  if ($hit -eq $c.E) { "OK  '{0}' -> {1}" -f $c.T, $hit }
  else { "FAIL '{0}' -> {1} (기대 {2})" -f $c.T, $hit, $c.E; $fails++ }
}

# 보조 신호: 좌측 점수표 판독의 '처치' + ('완벽' 또는 '보너스') 조합 (2026-07-19 실측 기반)
$scoreCases = @(
  @{ T = '처치완벽한전주권장전투력재도전보너스협동보너스11050201010'; E = $true }  # 클리어(hyodong) 실측
  @{ T = '처치완벽한전루재도전보너스협동보너스110501010'; E = $true }              # 클리어(User) 실측
  @{ T = '처치완벽한전투'; E = $true }                                             # 보너스 항목 없는 판 대비
  @{ T = '*42EI임무전리품이두배가됩니다'; E = $false }                             # 옵션 화면 실측
  @{ T = '과긴!견습쌍검사'; E = $false }                                           # 전투 중 실측
  @{ T = '처치'; E = $false }                                                      # 단독 조각은 불충분
  @{ T = ''; E = $false }
)
foreach ($c in $scoreCases) {
  $s = $c.T
  $hit = ($s.Contains('처치') -and ($s.Contains('완벽') -or $s.Contains('보너스')))
  if ($hit -eq $c.E) { "OK  점수표 '{0}' -> {1}" -f $c.T, $hit }
  else { "FAIL 점수표 '{0}' -> {1} (기대 {2})" -f $c.T, $hit, $c.E; $fails++ }
}
exit $fails
