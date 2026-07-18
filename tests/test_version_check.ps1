# 새 버전 알림의 버전 비교 판정 진리표 (네트워크 없이 판정식만)
# 본체: mabinogi_gui.ps1 업데이트 확인 타이머 핸들러
$fails = 0
$appVersion = '1.0.2'
$cases = @(
  @{ Tag = 'v1.0.3';  E = '표시 v1.0.3' }
  @{ Tag = '1.0.3';   E = '표시 v1.0.3' }
  @{ Tag = 'v1.0.10'; E = '표시 v1.0.10' }  # 문자열 비교였다면 1.0.2 > 1.0.10 으로 오판
  @{ Tag = 'v1.0.2';  E = '숨김(동일)' }
  @{ Tag = 'v1.0.1';  E = '숨김(구버전)' }
  @{ Tag = 'v2.0';    E = '표시 v2.0' }
  @{ Tag = '';        E = '숨김(파싱불가)' }
  @{ Tag = 'beta';    E = '숨김(파싱불가)' }
)
foreach ($c in $cases) {
  $remoteVersion = $null
  if (-not [System.Version]::TryParse(($c.Tag -replace '^[vV]', ''), [ref]$remoteVersion)) {
    $verdict = '숨김(파싱불가)'
  } elseif ($remoteVersion -le [System.Version]$appVersion) {
    $verdict = if ($remoteVersion -eq [System.Version]$appVersion) { '숨김(동일)' } else { '숨김(구버전)' }
  } else {
    $verdict = "표시 v$remoteVersion"
  }
  if ($verdict -eq $c.E) { "OK  태그 '{0}' -> {1}" -f $c.Tag, $verdict }
  else { "FAIL 태그 '{0}' -> {1} (기대 {2})" -f $c.Tag, $verdict, $c.E; $fails++ }
}
exit $fails
