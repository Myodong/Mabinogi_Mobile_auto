# 회귀 테스트 일괄 실행기 - Windows PowerShell 5.1 로 실행하세요:
#   powershell -ExecutionPolicy Bypass -File tests\run_all_tests.ps1
# 각 test_*.ps1 은 판정 로직의 진리표 테스트로, FAIL 줄이 있거나 종료 코드가 0이 아니면 실패.
# ※ 본체(mabinogi_run_once.ps1/gui)의 판정식을 바꾸면 해당 테스트의 사본 로직도 함께 갱신할 것.
$ErrorActionPreference = 'Stop'
$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tests = Get-ChildItem -Path $testDir -Filter 'test_*.ps1' | Sort-Object Name
$failedTests = @()
foreach ($t in $tests) {
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $t.FullName 2>&1
  $exit = $LASTEXITCODE
  $hasFail = ($out | Where-Object { $_ -match '^FAIL' }).Count -gt 0
  if ($exit -ne 0 -or $hasFail) {
    $failedTests += $t.Name
    "== $($t.Name): 실패 (exit $exit) =="
    $out | ForEach-Object { "  $_" }
  } else {
    "== $($t.Name): 통과 =="
  }
}
''
if ($failedTests.Count -gt 0) {
  "결과: $($tests.Count)개 중 $($failedTests.Count)개 실패 - $($failedTests -join ', ')"
  exit 1
}
"결과: $($tests.Count)개 전부 통과"
exit 0
