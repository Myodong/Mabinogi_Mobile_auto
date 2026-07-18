# PS 5.1 함수 배열 반환 함정 회귀 테스트
# 사고: return ,$words + 호출부 @() 조합이 '배열을 담은 1칸 배열'을 만들어
#       foreach 가 단어가 아닌 배열을 돌며 [int] 변환 오류 (2026-07-18 18:07 실측).
# 본체 규칙: 열거용은 return $arr + 호출부 @() / 단일 객체 유지용만 ,$arr
$fails = 0

function Get-WordsOld { $w = @(); $w += ,@{ T = 'a'; X = 1 }; $w += ,@{ T = 'b'; X = 2 }; return ,$w }
function Get-WordsNew { $w = @(); $w += ,@{ T = 'a'; X = 1 }; $w += ,@{ T = 'b'; X = 2 }; return $w }
function Get-WordsNewOne { $w = @(); $w += ,@{ T = 'a'; X = 1 }; return $w }
function Get-WordsNewEmpty { $w = @(); return $w }

# 구방식: @()로 감싸면 중첩 배열이 되고 요소의 .X 가 배열이 됨 (사고 재현 확인)
$m = @(Get-WordsOld)
if ($m.Count -eq 1 -and $m[0] -is [System.Array]) { 'OK  구방식(,$arr+@()) 중첩 재현 확인' }
else { "FAIL 구방식 중첩이 재현되지 않음 (count=$($m.Count))"; $fails++ }

# 신방식: 0/1/N개 모두 요소가 해시테이블이고 .X 가 스칼라
foreach ($case in @(
    @{ Name = 'N개'; F = ${function:Get-WordsNew}; Count = 2 },
    @{ Name = '1개'; F = ${function:Get-WordsNewOne}; Count = 1 },
    @{ Name = '0개'; F = ${function:Get-WordsNewEmpty}; Count = 0 }
  )) {
  $m = @(& $case.F)
  $ok = ($m.Count -eq $case.Count)
  foreach ($e in $m) { if (-not ($e -is [hashtable]) -or ($e.X -isnot [int])) { $ok = $false } }
  if ($ok) { "OK  신방식 {0}: count={1}, 요소 정상" -f $case.Name, $m.Count }
  else { "FAIL 신방식 {0}: count={1}" -f $case.Name, $m.Count; $fails++ }
}
exit $fails
