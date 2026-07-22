# 어비스 커스텀 반복 - 리스트 방식·매칭 통일 규칙 진리표 (2026-07-22 사용자 확정)
# 규칙: 리스트에 항목이 하나라도 있으면 그 리스트(첫 항목)의 방식+매칭으로 고정된다.
#       GUI 는 라디오 비활성으로 막고, config 직접 편집 대비로 시작 게이트에서 한 번 더 검사한다.
# 본체 순수 함수(Get-AbyssListLock / Get-AbyssMatchingIssues)를 AST 로 직접 불러 검사합니다.
$fails = 0

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $projectRoot 'mabinogi_gui.ps1'
. (Join-Path $PSScriptRoot 'source_test_helpers.ps1')
foreach ($definition in Get-SourceFunctionDefinitions -Path $guiPath `
    -Names @('Get-AbyssListLock', 'Get-AbyssMatchingIssues')) {
  Invoke-Expression $definition
}

function Check-Equal {
  param([string]$Name, $Actual, $Expected)
  if ([string]$Actual -eq [string]$Expected) {
    Write-Host ("PASS {0} (= '{1}')" -f $Name, $Actual)
  } else {
    Write-Host ("FAIL {0}: got '{1}' expected '{2}'" -f $Name, $Actual, $Expected)
    $script:fails++
  }
}

function NewAcr([string]$mode, [string]$matching) {
  [pscustomobject]@{ kind = 'abyss'; mode = $mode; difficulty = '어려움'
    dungeon = '허상의 정박지'; matching = $matching }
}

function LockText($items) {
  $lock = Get-AbyssListLock -Items $items
  if ($null -eq $lock) { return 'none' }
  return ('{0}/{1}' -f $lock.Mode, $lock.Matching)
}

function IssueIndexes($items) {
  # 위반 항목 번호를 순서대로 이은 문자열 (없으면 '')
  return ((@(Get-AbyssMatchingIssues -Items $items) | ForEach-Object { [string]$_.Index }) -join ',')
}

$solo = NewAcr 'solo' '없음'
$chance = NewAcr 'party' '우연한 만남'
$find = NewAcr 'party' '파티 찾기'
$lead = NewAcr 'party' '파티(파티장)'

# ----- Get-AbyssListLock 진리표 -----
Check-Equal 'lock-빈 리스트' (LockText @()) 'none'
Check-Equal 'lock-null만 든 리스트' (LockText @($null, $null)) 'none'
Check-Equal 'lock-혼자하기 1개' (LockText @($solo)) 'solo/없음'
Check-Equal 'lock-혼자하기만' (LockText @($solo, $solo)) 'solo/없음'
Check-Equal 'lock-함께하기+우연한 만남' (LockText @($chance, $chance)) 'party/우연한 만남'
Check-Equal 'lock-함께하기+파티 찾기' (LockText @($find, $find)) 'party/파티 찾기'
Check-Equal 'lock-함께하기+파티장' (LockText @($lead)) 'party/파티(파티장)'
# 첫 항목 기준 - 뒤가 달라도 잠금값은 첫 항목의 것
Check-Equal 'lock-첫 항목 기준' (LockText @($find, $solo, $chance)) 'party/파티 찾기'
# config 직접 편집 표기 흔들림 정규화 (공백 없는 '파티찾기', 한글 방식명)
Check-Equal 'lock-공백 없는 파티찾기 정규화' (LockText @((NewAcr 'party' '파티찾기'))) 'party/파티 찾기'
Check-Equal 'lock-한글 방식명 party 정규화' (LockText @((NewAcr '함께하기' '우연한 만남'))) 'party/우연한 만남'
# 혼자하기 항목에 매칭이 잘못 적혀 있어도 '없음'으로 본다
Check-Equal 'lock-혼자하기 매칭 무시' (LockText @((NewAcr 'solo' '파티 찾기'))) 'solo/없음'

# ----- Get-AbyssMatchingIssues 진리표 -----
Check-Equal 'issue-빈 리스트' (IssueIndexes @()) ''
Check-Equal 'issue-항목 1개' (IssueIndexes @($chance)) ''
Check-Equal 'issue-혼자하기만' (IssueIndexes @($solo, $solo, $solo)) ''
Check-Equal 'issue-함께하기+우연한 만남만' (IssueIndexes @($chance, $chance)) ''
Check-Equal 'issue-함께하기+파티찾기만' (IssueIndexes @($find, $find, $find)) ''
Check-Equal 'issue-표기만 다른 파티찾기는 위반 아님' (IssueIndexes @($find, (NewAcr 'party' '파티찾기'))) ''
Check-Equal 'issue-방식 혼합(2번)' (IssueIndexes @($solo, $chance)) '2'
Check-Equal 'issue-방식 혼합(3번)' (IssueIndexes @($chance, $chance, $solo)) '3'
Check-Equal 'issue-매칭 혼합(2번)' (IssueIndexes @($chance, $find)) '2'
Check-Equal 'issue-매칭 혼합 다중(2,4번)' (IssueIndexes @($chance, $lead, $chance, $find)) '2,4'
Check-Equal 'issue-혼자하기 리스트에 함께하기 삽입(2,3번)' (IssueIndexes @($solo, $find, $chance)) '2,3'

# 위반 항목의 번호·사유 문구 (게이트 로그에 그대로 실리는 값)
$mixIssues = @(Get-AbyssMatchingIssues -Items @($solo, $find))
Check-Equal 'issue-방식 위반 건수' $mixIssues.Count 1
Check-Equal 'issue-방식 위반 번호' $mixIssues[0].Index 2
Check-Equal 'issue-방식 위반 방식표기' $mixIssues[0].Mode '함께하기'
Check-Equal 'issue-방식 위반 사유' $mixIssues[0].Reason "리스트의 방식은 '혼자하기'인데 이 항목은 '함께하기'입니다"

$matchIssues = @(Get-AbyssMatchingIssues -Items @($chance, $lead))
Check-Equal 'issue-매칭 위반 번호' $matchIssues[0].Index 2
Check-Equal 'issue-매칭 위반 매칭표기' $matchIssues[0].Matching '파티(파티장)'
Check-Equal 'issue-매칭 위반 사유' $matchIssues[0].Reason "리스트의 매칭은 '우연한 만남'인데 이 항목은 '파티(파티장)'입니다"

# ----- GUI 배선 검사 (라디오 잠금·툴팁·갱신 시점·시작 게이트) -----
$gui = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
function Check-Pattern {
  param([string]$Name, [string]$Pattern)
  if ($gui -match $Pattern) { Write-Host ("PASS {0}" -f $Name) }
  else { Write-Host ("FAIL {0}" -f $Name); $script:fails++ }
}

Check-Pattern '방식·매칭 라디오 5종 Enabled 잠금' `
  '\$rbAcrSolo\.Enabled\s*=\s*-not \$acrLockOn[\s\S]{0,300}\$rbAcrParty\.Enabled\s*=\s*-not \$acrLockOn[\s\S]{0,300}\$rbAcrChance\.Enabled\s*=\s*-not \$acrLockOn[\s\S]{0,300}\$rbAcrFindParty\.Enabled\s*=\s*-not \$acrLockOn[\s\S]{0,300}\$rbAcrPartyLead\.Enabled\s*=\s*-not \$acrLockOn'
Check-Pattern '잠글 때 리스트 값으로 라디오 Checked 보정' `
  '\$acrLock\.Mode -eq ''party''[\s\S]{0,600}\$rbAcrFindParty\.Checked = \$true[\s\S]{0,400}\$rbAcrPartyLead\.Checked = \$true'
Check-Pattern '라디오 보정 시 저장 이벤트 가드 사용' `
  'function Update-AbyssInputLock[\s\S]{0,900}\$script:crLoading = \$true'
Check-Pattern '재진입 가드' `
  'function Update-AbyssInputLock[\s\S]{0,600}if \(\$script:acrLockUpdating\) \{ return \}'
Check-Pattern '잠금 상태를 툴팁 판정용으로 보관' `
  '\$script:acrLockOn = \$acrLockOn'
Check-Pattern '잠긴 라디오 위 툴팁 - 패널 MouseMove 로 직접 판정' `
  '\$tipCtl -is \[System\.Windows\.Forms\.RadioButton\][\s\S]{0,120}-not \$tipCtl\.Enabled[\s\S]{0,120}\$tipCtl\.Bounds\.Contains'
Check-Pattern '같은 컨트롤에서 툴팁 재호출 안 함 (깜박임 방지)' `
  'if \(\$script:acrTipShownFor -ne \$tipHit\)[\s\S]{0,200}\$toolTip\.Show\('
Check-Pattern '패널 이탈 시 툴팁 숨김' `
  'Add_MouseLeave\(\$acrLockTipLeave\)'
Check-Pattern '툴팁 문구' `
  '리스트의 방식·매칭과 같아야 합니다\. 바꾸려면 리스트를 비워 주세요\.'
Check-Pattern '추가 후 잠금 갱신' `
  '\$btnAcrAdd\.Add_Click\(\{[\s\S]{0,900}Update-AbyssInputLock'
Check-Pattern '삭제 후 잠금 갱신' `
  '\$btnAcrDelete\.Add_Click\(\{[\s\S]{0,900}Update-AbyssInputLock'
Check-Pattern '이동 후 잠금 갱신' `
  'function Move-AbyssCustomListRow[\s\S]{0,900}Update-AbyssInputLock'
Check-Pattern '설정 복원 후 잠금 갱신' `
  'function Load-SettingsToUi[\s\S]{0,60000}Update-AbyssInputLock'
Check-Pattern '카테고리·모드 전환 후 잠금 갱신' `
  '\$updateCategoryPanels = \{[\s\S]{0,12000}Update-AbyssInputLock[\s\S]{0,20}\}'
Check-Pattern '시작 게이트에서 어비스 통일 검사' `
  'abyssCustomRepeat''\s*\)\s*\{\s*\r?\n\s*\$acrGateIssues = @\(Get-AbyssMatchingIssues -Items \$crItems\)'
Check-Pattern '게이트 위반 시 시작 거부' `
  '\$acrGateIssues\.Count -gt 0[\s\S]{0,900}\$script:customActive = \$false[\s\S]{0,40}return'

exit $fails
