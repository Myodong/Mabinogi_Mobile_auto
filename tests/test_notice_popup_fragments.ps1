# 공지 게시판 팝업 감지 판정 진리표
# 본체: mabinogi_run_once.ps1 Test-NoticeBoardPopup ('쿠폰' 또는 '공지'+'이벤트' 조합)
$fails = 0
$cases = @(
  @{ T = '공지사항이벤트쿠폰입력FAQ'; E = $true }   # 2026-07-19 hyodong 실측 판독
  @{ T = '쿠폰입력'; E = $true }
  @{ T = '공지사항이벤트'; E = $true }
  @{ T = '공지사항'; E = $false }                    # 단독으로는 오탐 방지
  @{ T = '이벤트'; E = $false }
  @{ T = '월드채팅어쩌고'; E = $false }
  @{ T = ''; E = $false }
)
foreach ($c in $cases) {
  $text = $c.T
  if (-not $text) { $hit = $false }
  elseif ($text.Contains('쿠폰')) { $hit = $true }
  else { $hit = ($text.Contains('공지') -and $text.Contains('이벤트')) }
  if ($hit -eq $c.E) { "OK  '{0}' -> {1}" -f $c.T, $hit }
  else { "FAIL '{0}' -> {1} (기대 {2})" -f $c.T, $hit, $c.E; $fails++ }
}
exit $fails
