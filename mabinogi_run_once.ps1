$ErrorActionPreference = 'Stop'

# 초기화 구간(아래 메인 try 이전: config 읽기, 형 변환, WinRT/OCR 준비 등)에서 예외가 나면
# 로그 없이 조용히 죽어 GUI에는 '오류 종료(코드 1)'만 뜹니다. 원인을 로그 파일에 남기고 끝냅니다.
# (메인 흐름의 예외는 아래쪽 try/catch가 먼저 잡아 진단까지 남기므로 이 trap에 오지 않습니다)
trap {
  try {
    $bootLogDir = Join-Path $PSScriptRoot 'Log'
    if (-not (Test-Path -LiteralPath $bootLogDir)) {
      New-Item -ItemType Directory -Path $bootLogDir -Force | Out-Null
    }
    Add-Content -LiteralPath (Join-Path $bootLogDir 'mabinogi_run_once.log') `
      -Value ("{0} [오류] 시작 준비 중 오류: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) `
      -Encoding UTF8
  } catch { }
  exit 1
}

# ===== 설정 로드 =====
# 같은 폴더의 config.json 에서 좌표·타임아웃·OCR 영역 등을 읽습니다.
# config.json 이 없거나 항목이 빠지면 각 항목의 기본값(두 번째 인자)을 사용합니다.
function Get-ConfigValue {
  param([object]$Root, [string[]]$Path, $Default)
  $node = $Root
  foreach ($key in $Path) {
    if ($null -eq $node) { return $Default }
    $prop = $node.PSObject.Properties[$key]
    if (-not $prop -or $null -eq $prop.Value) { return $Default }
    $node = $prop.Value
  }
  if ($null -eq $node) { return $Default }
  return $node
}

$config = $null
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path -LiteralPath $configPath) {
  try {
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Write-Host "config.json 을 읽지 못해 기본값으로 진행합니다: $($_.Exception.Message)" -ForegroundColor Yellow
    $config = $null
  }
}

# ===== 좌표 버전 게이트 =====
# exe 는 config.json 을 '처음 한 번만' 풀기 때문에, 게임 UI 개편으로 좌표가 바뀌어도
# 옛 config 의 좌표가 내장 최신 기본값을 계속 덮어쓰는 사고가 납니다
# (실측 2026-07-17: 다른 PC의 옛 config 가 개편 전 abyssMenu(1028,510)를 갖고 있어
#  길드 부근을 16회 헛클릭). config 의 coordsVersion 이 아래 값보다 낮으면
# 좌표 섹션(ocrRegions/clickPoints)을 무시하고 스크립트 내장 최신 좌표를 사용합니다.
# ※ 좌표를 직접 수정해 쓰려면 config 에 "coordsVersion": <아래 값> 을 함께 적어 주세요.
# ※ 개발 규칙: 이 파일의 좌표 기본값(ocrRegions/clickPoints 계열)을 하나라도 바꾸면
#    아래 버전과 config.json 의 coordsVersion 을 반드시 함께 +1 하세요.
#    (안 올리면 옛 config 의 좌표가 게이트를 통과해 이번 사고가 재발합니다.
#     두 값이 어긋나면 빌드 스크립트가 실패하도록 검사합니다)
$coordsVersionCurrent = 6
$script:staleCoordsIgnored = $false
if ($config -and ([int](Get-ConfigValue $config @('coordsVersion') 0)) -lt $coordsVersionCurrent) {
  if ($config.PSObject.Properties['ocrRegions'] -or $config.PSObject.Properties['clickPoints']) {
    $config.PSObject.Properties.Remove('ocrRegions')
    $config.PSObject.Properties.Remove('clickPoints')
    $script:staleCoordsIgnored = $true
  }
}

$referenceWidth  = [int](Get-ConfigValue $config @('referenceResolution', 'width') 1272)
$referenceHeight = [int](Get-ConfigValue $config @('referenceResolution', 'height') 717)

$timeoutDetail      = [int](Get-ConfigValue $config @('timeoutsSeconds', 'detailScreen') 15)
$timeoutEntry       = [int](Get-ConfigValue $config @('timeoutsSeconds', 'dungeonEntry') 45)
$timeoutClear       = [int](Get-ConfigValue $config @('timeoutsSeconds', 'dungeonClear') 600)
$timeoutExit        = [int](Get-ConfigValue $config @('timeoutsSeconds', 'exitButton') 20)
$timeoutHud         = [int](Get-ConfigValue $config @('timeoutsSeconds', 'homeEndEscHud') 30)
$timeoutAbyssMenu   = [int](Get-ConfigValue $config @('timeoutsSeconds', 'abyssMenu') 15)
$timeoutAbyssSelect = [int](Get-ConfigValue $config @('timeoutsSeconds', 'abyssSelectionScreen') 15)

$ptAbyssCard   = @(Get-ConfigValue $config @('clickPoints', 'abyssCard') @(956, 157))

# 선택된 던전 프로파일: config.dungeons.selected 로 대상 던전이 정해지고,
# 카드 클릭 좌표와 로그 문구가 그 던전 기준으로 바뀝니다. (UI에서 선택 시 자동 기록)
$selectedDungeon = [string](Get-ConfigValue $config @('dungeons', 'selected') '허상의 정박지')
if ([string]::IsNullOrWhiteSpace($selectedDungeon)) { $selectedDungeon = '허상의 정박지' }
# 내장 최신 어비스 카드 좌표 (config.json profiles 와 동일 값 유지).
# 좌표 버전 게이트가 발동하면 구버전 profiles.<던전>.card 대신 이 값을 씁니다.
$builtinDungeonCards = @{
  '허상의 정박지' = @(956, 157)
  '광기의 동굴'   = @(956, 272)
  '흩어진 물길'   = @(956, 387)
}
$dungeonCard = $ptAbyssCard
$dungeonStage = 'full'   # full = 전체 자동화 / detail = 상세 화면 진입까지만(이후 미개발)
$dungeonMatch = $selectedDungeon.Substring(0, [Math]::Min(2, $selectedDungeon.Length))  # 제목 확인용 키워드(기본: 이름 앞 2글자)
$dungeonProfiles = Get-ConfigValue $config @('dungeons', 'profiles') $null
if ($dungeonProfiles) {
  $selectedProfile = $dungeonProfiles.PSObject.Properties[$selectedDungeon]
  if ($selectedProfile) {
    if ($selectedProfile.Value.PSObject.Properties['card']) {
      $dungeonCard = @($selectedProfile.Value.card)
    }
    if ($selectedProfile.Value.PSObject.Properties['stage'] -and $selectedProfile.Value.stage) {
      $dungeonStage = [string]$selectedProfile.Value.stage
    }
    if ($selectedProfile.Value.PSObject.Properties['match'] -and $selectedProfile.Value.match) {
      $dungeonMatch = [string]$selectedProfile.Value.match
    }
  }
}
# 좌표 버전 게이트 보강 (2026-07-19 개선점): ocrRegions/clickPoints 는 위에서 통째로
# 무시되지만 어비스 카드 좌표는 dungeons.profiles.<던전>.card 에도 있어 게이트를
# 빠져나갔음. 게이트 발동 시 카드 좌표만 내장 최신값으로 대체하고, 사용자 선택값
# (selected/stage/match)은 좌표가 아니므로 그대로 유지합니다.
# (내장 목록에 없는 미래 던전이면 대체할 값이 없어 profiles 값을 그대로 씀 - 한계 명시)
if ($script:staleCoordsIgnored -and $builtinDungeonCards.ContainsKey($selectedDungeon)) {
  $dungeonCard = @($builtinDungeonCards[$selectedDungeon])
}

# 모든 던전의 제목 키워드 목록: "지금 화면이 (어느 던전이든) 상세 화면인가"를 판단할 때 사용
$allDungeonKeywords = @('정박', '광기', '물길')
if ($dungeonProfiles) {
  $keywordList = @()
  foreach ($profileProp in $dungeonProfiles.PSObject.Properties) {
    if ($profileProp.Value.PSObject.Properties['match'] -and $profileProp.Value.match) {
      $keywordList += [string]$profileProp.Value.match
    }
  }
  if ($keywordList.Count -gt 0) { $allDungeonKeywords = $keywordList }
}
$ptEnter       = @(Get-ConfigValue $config @('clickPoints', 'enter') @(981, 654))
$ptClearCenter = @(Get-ConfigValue $config @('clickPoints', 'clearScreenCenter') @(636, 358))
$ptExitButton  = @(Get-ConfigValue $config @('clickPoints', 'exitButton') @(636, 655))
$ptEscButton   = @(Get-ConfigValue $config @('clickPoints', 'escButton') @(1083, 89))
$ptAbyssMenu   = @(Get-ConfigValue $config @('clickPoints', 'abyssMenu') @(971, 387))   # 2026-07-16 UI 개편: 아이콘 그리드 메뉴의 '어비스' 타일 (OCR 실측)

$rgClearExit   = @(Get-ConfigValue $config @('ocrRegions', 'clearAndExitText') @(430, 570, 420, 125))
$rgEnterButton = @(Get-ConfigValue $config @('ocrRegions', 'enterButton') @(880, 630, 200, 48))
$rgHomeEndEsc  = @(Get-ConfigValue $config @('ocrRegions', 'homeEndEsc') @(875, 60, 265, 55))
$rgAbyssMenu   = @(Get-ConfigValue $config @('ocrRegions', 'abyssMenu') @(850, 330, 350, 85))   # 2026-07-16 UI 개편: '필드 보스/어비스/망령의 탑/레이드' 줄 (OCR 실측)
$rgAbyssCards  = @(Get-ConfigValue $config @('ocrRegions', 'abyssCards') @(690, 110, 280, 310)) # 어비스 선택 화면 우측 던전 배너 3장의 제목 영역 (2026-07-16 개편 화면 실측)
$rgMenuExitLabel = @(Get-ConfigValue $config @('ocrRegions', 'menuExitLabel') @(1160, 600, 112, 90)) # ESC 메뉴 우하단 '게임 종료' 문구 (메뉴 열림 2차 신호, 두 창 크기 실측)
$rgNoticeTabs    = @(170, 495, 930, 62)   # 공지 게시판 팝업 하단 탭 줄(공지사항/이벤트/쿠폰 입력/FAQ) - 2026-07-19 hyodong 캡처 실측
$ptNoticeClose   = @(1092, 135)           # 공지 게시판 팝업 우상단 X - 같은 캡처 실측 (공용 X 후보 1090,137과 동일 계열)
$rgAbyssSelect = @(Get-ConfigValue $config @('ocrRegions', 'abyssSelectionTitle') @(0, 25, 240, 95))
$rgDetailTitle = @(Get-ConfigValue $config @('ocrRegions', 'detailTitle') @(30, 100, 350, 65))
$ptDetailBack  = @(Get-ConfigValue $config @('clickPoints', 'detailBack') @(43, 67))
$ptSoloTab     = @(Get-ConfigValue $config @('clickPoints', 'soloTab') @(533, 76))
$ptPartyTab    = @(Get-ConfigValue $config @('clickPoints', 'partyTab') @(760, 76))

# 함께하기 화면 전용 (2026-07-16 실측): 하단 버튼이 토글 상태에 따라 달라집니다 -
# 우연한 만남 꺼짐 = '파티원 모집'+'입장하기' 2버튼 / 켜짐 = 넓은 단일 '입장하기'.
# 클릭 지점과 글자 영역은 두 레이아웃을 모두 커버하도록 잡았습니다 (실측 검증).
$ptPartyEnter        = @(Get-ConfigValue $config @('clickPoints', 'partyEnter') @(1077, 655))       # 함께하기 '입장하기' 버튼 (두 레이아웃 모두 버튼 안)
$ptPartyFind         = @(Get-ConfigValue $config @('clickPoints', 'partyFind') @(836, 655))          # 함께하기 '파티 찾기' 버튼 (토글 꺼짐 레이아웃 전용, 실측)
$ptAbyssChanceToggle = @(Get-ConfigValue $config @('clickPoints', 'abyssChanceToggle') @(1208, 339)) # '우연한 만남' 토글 (켜짐 초록 13,179,118 실측)
$rgPartyEnterBtn     = @(Get-ConfigValue $config @('ocrRegions', 'partyEnterButton') @(900, 630, 260, 48)) # 함께하기 '입장하기' 글자 영역 (두 레이아웃 커버)

# 입장 방식: solo = 혼자하기 / party = 함께하기 (우연한 만남 매칭 자동화 지원)
$dungeonMode = [string](Get-ConfigValue $config @('dungeons', 'mode') 'solo')
if ($dungeonMode -ne 'party') { $dungeonMode = 'solo' }
# 함께하기 매칭 방식: '우연한 만남'(토글 켜고 입장 - 모이면 자동 입장) / '파티찾기'(토글 끄고
# 파티 찾기 클릭) / '파티(파티장)'(직접 짠 파티로 입장하기 클릭 주도 - 전원 준비되면 자동 입장,
# 인원이 부족해도 채우지 않고 도전 확인 팝업을 Space 로 확인) / '파티(파티원)'(필드 대기 →
# 파티장이 입장 시작하면 '준비 완료' 클릭 → 따라 입장, 전용 사이클)
$abyssMatching = [string](Get-ConfigValue $config @('dungeons', 'matching') '우연한 만남')
# 과도기 config 호환: 잠시 파티 상태가 dungeons.partyState 로 분리 저장된 버전이 있었습니다
$legacyPartyState = [string](Get-ConfigValue $config @('dungeons', 'partyState') '')
if ($legacyPartyState -eq '파티(파티장)' -or $legacyPartyState -eq '파티(파티원)') { $abyssMatching = $legacyPartyState }
if ($abyssMatching -eq '파티원') { $abyssMatching = '파티(파티장)' }

# 난이도: 입장 전 상세 화면에서 클릭할 난이도 이름 (예: '입문', '어려움', '매우 어려움').
# 빈 값이면 난이도를 건드리지 않고 게임에 선택돼 있는 그대로 입장합니다.
$dungeonDifficulty = [string](Get-ConfigValue $config @('dungeons', 'difficulty') '')
# 상세 화면에서 난이도 버튼들(입문/어려움/매우 어려움...)이 표시되는 좌상단 영역.
# 난이도가 추가되어 버튼 위치가 바뀌어도 되도록, 이 영역에서 글자를 OCR로 찾아 클릭합니다.
$rgDifficultyTabs  = @(Get-ConfigValue $config @('ocrRegions', 'difficultyTabs') @(30, 150, 500, 60))

# 아침 6시 리셋 후 뜨는 출석/이벤트 화면 처리용 영역 (2026-07-15 실측):
#  - eventSkip: 출석부 우상단 '출석부 건너뛰기' 버튼 영역
#  - eventConfirm: '출석 완료' 보상 요약 하단 '확인' 버튼 영역
$rgEventSkip    = @(Get-ConfigValue $config @('ocrRegions', 'eventSkip') @(1110, 45, 155, 45))
$rgEventConfirm = @(Get-ConfigValue $config @('ocrRegions', 'eventConfirm') @(480, 625, 320, 55))
# '출석 완료 / 우편으로 지원품이 지급되었습니다' 보상 요약 화면 - 하단 초록 버튼이
# 마우스 클릭 대신 Space 확인이라, 이 문구('지원')가 보이면 Space로 넘깁니다 (2026-07-17 실측)
$rgEventReward  = @(Get-ConfigValue $config @('ocrRegions', 'eventReward') @(480, 190, 320, 100))
# 아침 6시 알리사 NPC 대화(출석 전 도입 장면)의 말풍선 영역: 글자가 보이면 대화 진행 중으로
# 판단하고 중앙 클릭으로 넘깁니다 (실측 2026-07-17: '있잖아, 부꼼~ 그거 봤어?' 정상 인식)
$rgNpcDialogue  = @(Get-ConfigValue $config @('ocrRegions', 'npcDialogue') @(450, 115, 380, 80))
# '오늘의 스텔라 픽' 데일리 팝업 (2026-07-16 실측): 좌상단 제목으로 감지하고,
# 카드 3장 중 가운데를 골라 진행. 두 번 골라도 남아 있으면 우상단 닫기(X)로 닫음
$rgStellaTitle  = @(Get-ConfigValue $config @('ocrRegions', 'stellaTitle') @(50, 45, 230, 45))
# 2단계(확정 화면): 카드 캐러셀 + 하단 초록 '스텔라 픽' 버튼 (2026-07-17 실측: 중심 968,654)
$rgStellaPickBtn = @(Get-ConfigValue $config @('ocrRegions', 'stellaPickButton') @(740, 632, 450, 50))
# 공지 팝업의 '오늘 그만 보기'(팝업 좌하단)와 이벤트 팝업의 '닫기' 버튼 영역 (2026-07-17 실측)
# 팝업 높이가 공지 내용에 따라 달라질 수 있어 세로로 넉넉히 잡습니다
$rgEventTodayOff = @(Get-ConfigValue $config @('ocrRegions', 'eventTodayOff') @(250, 430, 520, 120))
$rgEventCloseBtn = @(Get-ConfigValue $config @('ocrRegions', 'eventCloseButton') @(100, 600, 550, 80))
# 웹뷰형 공지 보드(공지사항/이벤트/쿠폰 입력/FAQ 탭): 탭 글자로 감지하고 전용 X 로 닫음 (2026-07-17 실측)
$rgNoticeBoardTabs  = @(Get-ConfigValue $config @('ocrRegions', 'noticeBoardTabs') @(600, 500, 480, 55))
$ptNoticeBoardClose = @(Get-ConfigValue $config @('clickPoints', 'noticeBoardClose') @(1090, 137))
$ptStellaCard   = @(Get-ConfigValue $config @('clickPoints', 'stellaCard') @(640, 420))
$ptStellaClose  = @(Get-ConfigValue $config @('clickPoints', 'stellaClose') @(1229, 67))   # 전체 화면 UI 공용 닫기(X) 위치 (스텔라 픽/인벤토리 실측 동일)
# 우측 퀘스트 추적기 첫 줄 영역: 던전 안에서는 '<던전 이름> 클리어' 목표가 고정 표시되므로
# 이 글자로 '던전 안'과 '필드(던전 밖)'를 구분합니다 (HUD는 양쪽 다 보여서 구분 불가).
$rgQuestTracker = @(Get-ConfigValue $config @('ocrRegions', 'questTracker') @(980, 212, 285, 55))

# 캐릭터가 던전에서 먼 곳에 있어 상세 화면에 '이동하기'가 뜬 경우, 자동 이동으로
# 던전에 도착(상세 화면이 다시 열리며 '입장하기' 표시)할 때까지 기다리는 최대 시간(초)
$timeoutTravel = [int](Get-ConfigValue $config @('timeoutsSeconds', 'travelToDungeon') 180)
# 던전 '파티 찾기' 매칭이 완료되어 던전에 입장할 때까지 기다리는 최대 시간(초)
$timeoutPartyMatch = [int](Get-ConfigValue $config @('timeoutsSeconds', 'partyMatching') 300)

# 보스방 진입 컷신의 '장면 넘기기' 버튼 탐색 영역: 정확한 버튼 위치가 화면마다 다를 수
# 있어 상단/하단 오른쪽 절반을 넓게 잡고, '넘기' 글자를 OCR로 찾아 그 위치를 클릭합니다.
$rgCutsceneTop    = @(Get-ConfigValue $config @('ocrRegions', 'cutsceneSkipTop') @(636, 40, 630, 70))
$rgCutsceneBottom = @(Get-ConfigValue $config @('ocrRegions', 'cutsceneSkipBottom') @(636, 590, 630, 110))

# 구매 제안 팝업(회복 물약 부족 등)의 '닫기' 버튼 탐색 영역: 팝업이 뜨면 화면 중앙을
# 덮어 모든 감지가 가려지므로, 이 영역에서 '닫기' 글자를 찾아 클릭해 닫습니다 (실측 검증됨).
$rgPopupClose = @(Get-ConfigValue $config @('ocrRegions', 'popupClose') @(380, 590, 320, 60))

# ===== '던전' 카테고리 설정 (전체 자동화 구현: 선택 → 옵션 → 입장 → 클리어 → 다시 하기 반복) =====
$contentCategory = [string](Get-ConfigValue $config @('contentCategory') 'abyss')
$ndDifficulty    = [string](Get-ConfigValue $config @('normalDungeon', 'difficulty') '일반')
$ndStage         = [string](Get-ConfigValue $config @('normalDungeon', 'stage') '1-1')
$ndUseCoin       = [bool](Get-ConfigValue $config @('normalDungeon', 'useSilverCoin') $false)
$ndDoubleLoot    = [bool](Get-ConfigValue $config @('normalDungeon', 'doubleLoot') $false)
$ndCoinFallback  = [bool](Get-ConfigValue $config @('normalDungeon', 'continueWithoutCoin') $false)
$ndLootFallback  = [bool](Get-ConfigValue $config @('normalDungeon', 'continueSweepOnly') $false)
$ndMatching      = [string](Get-ConfigValue $config @('normalDungeon', 'matching') '우연한 만남')
# 던전 선택/옵션 화면의 OCR 영역들 (2026-07-15 실측 검증)
$rgDgTitle      = @(Get-ConfigValue $config @('ocrRegions', 'dgTitle') @(30, 45, 250, 55))        # 좌상단 제목 (선택: '○○ 던전' / 옵션: 'N층 M구역') - 기본값은 config.json과 동일하게 유지
$rgDgDifficulty = @(Get-ConfigValue $config @('ocrRegions', 'dgDifficulty') @(30, 165, 200, 50))  # 일반/어려움 알약
$rgDgEnterBtn   = @(Get-ConfigValue $config @('ocrRegions', 'dgEnterButton') @(660, 620, 520, 70)) # 'N층 M구역 진입' 버튼
# 은동전/더블 루팅 카드 버튼은 상태별로 위치·폭이 달라('선택됨'=넓고 우측 / '도전'=좁고 좌측)
# 한 영역으로 두 상태를 다 읽지 못합니다. 그래서 각 카드마다 주 영역 + 보조 영역을 두고,
# 주 영역에서 판별이 안 되면 보조 영역을 읽습니다 (Set-DgToggleCard의 AltRegion).
$rgDgCoinButton = @(Get-ConfigValue $config @('ocrRegions', 'dgCoinButton') @(388, 300, 205, 50))     # 은동전 주: 넓은 영역 ('선택됨' 대응, 실측 검증)
$rgDgCoinButtonAlt = @(Get-ConfigValue $config @('ocrRegions', 'dgCoinButtonAlt') @(400, 292, 130, 44)) # 은동전 보조: 좁은 영역 ('도전' 대응)
$rgDgLootButton = @(Get-ConfigValue $config @('ocrRegions', 'dgLootButton') @(388, 494, 130, 48))     # 더블 루팅 주: 좁은 영역 ('도전' 대응, 실측 검증)
$rgDgLootButtonAlt = @(Get-ConfigValue $config @('ocrRegions', 'dgLootButtonAlt') @(388, 493, 205, 50)) # 더블 루팅 보조: 넓은 영역 ('선택됨' 대응)
# 스테이지 노드 클릭 좌표 (기준 1272x717, 2026-07-18 실측 캡처 기준으로 리베이스).
# 지도는 세로 스크롤 패널이라 위치가 흐르므로, 클릭 전에 라벨을 읽어 오프셋을 보정하고
# (Get-NdStageClickPoint), 클릭 후 진입 버튼 문구('N층 M구역')로 선택 결과를 검증합니다.
$ndStagePoints = @{
  '1-1' = @(196, 406); '1-2' = @(293, 406); '1-3' = @(385, 367)
  '2-1' = @(249, 655); '2-2' = @(249, 571); '2-3' = @(353, 605)
}
# 지도 라벨 앵커: 위 기준 좌표와 같은 스크롤 상태에서 각 라벨 글자의 기준 y.
# 지도가 밀리면 (읽힌 라벨 y - 기준 y)를 노드 좌표에 더해 보정합니다.
# (작은 노드 라벨(1-1/1-2/2-1)은 OCR이 자주 못 읽지만 큰 카드/층 제목은 잘 읽힘 - 실측)
$ndMapAnchorY = @{
  '1층' = 259; '2층' = 503
  '1-1' = 415; '1-2' = 415; '1-3' = 398
  '2-1' = 664; '2-2' = 580; '2-3' = 637
}
$rgNdStageMap = @(40, 230, 520, 470)   # 스테이지 지도 라벨 판독 영역
# ===== '사냥터' 카테고리 설정 - 특정 사냥터에 매이지 않는 범용 방식 =====
# 사용자가 원하는 사냥터의 첫 화면(하단에 파티 찾기/입장하기)을 열어 두면 동작합니다.
$htDifficulty   = [string](Get-ConfigValue $config @('huntingGround', 'difficulty') '일반')
# 사냥터 소진 대응 (사용자 결정 2026-07-18): '소진 시 미사용으로 계속'은 없습니다 -
# 은동전이 10개 미만이면 사냥터에서 나가서(우상단 X) 자동화를 마칩니다 (코드 4).
# 단 continueSweepOnly(더블 루팅 불가 시 소탕만 계속)는 유지: 잔량 10~19개면
# 더블 루팅만 끄고 소탕(10개)으로 계속합니다.
$htUseCoin      = [bool](Get-ConfigValue $config @('huntingGround', 'useOffering') $false)
$htDoubleLoot   = [bool](Get-ConfigValue $config @('huntingGround', 'doubleLoot') $false)
$htLootFallback = [bool](Get-ConfigValue $config @('huntingGround', 'continueSweepOnly') $false)
$htMatching     = [string](Get-ConfigValue $config @('huntingGround', 'matching') '파티찾기')
# 사냥터 첫 화면의 영역/좌표 (2026-07-15 창백한 산 화면 실측 - 모든 사냥터 공통 배치)
$rgHtDifficulty = @(Get-ConfigValue $config @('ocrRegions', 'htDifficulty') @(560, 100, 330, 45))  # 난이도 알약 (상단 중앙, 매우 어려움 3개 배치까지 커버)
# 임무 카드 버튼: 카드의 설명 줄 수에 따라 버튼 위치가 달라집니다 (2026-07-18 실측:
# 1줄 카드 = y292 / 2줄 카드 = y322). 두 위치를 모두 덮는 세로 확장 영역을 씁니다.
# (이 x 구간(388~530)에는 버튼 외 다른 글자가 없어 넓혀도 안전 - 실측 확인)
$rgHtCardButton = @(Get-ConfigValue $config @('ocrRegions', 'htCardButton') @(400, 288, 130, 80))  # 은동전 임무 카드의 '선택됨'/'도전' 버튼
$rgHtCardButtonAlt = @(Get-ConfigValue $config @('ocrRegions', 'htCardButtonAlt') @(388, 286, 205, 84)) # 보조: 넓은 영역 (버튼 상태별 위치·폭 차이 대응)
$rgHtEnterBtn   = @(Get-ConfigValue $config @('ocrRegions', 'htEnterButton') @(930, 632, 230, 50)) # 하단 입장 버튼 글자 (첫 화면 감지용 - 첫 진입 '입장하기' / 새 임무 선택 복귀 후 '임무 시작')
$ptHtCardButton = @(463, 330)      # 클릭 지점: 1줄(버튼 292~335)/2줄(322~364) 두 배치 모두 버튼 안 (실측)
# 더블 루팅 카드: 임무 카드 줄 수에 따라 같이 내려갑니다 (1줄 = y494 / 2줄 = y524 실측)
$rgHtLootButton = @(Get-ConfigValue $config @('ocrRegions', 'htLootButton') @(388, 490, 130, 82))
$rgHtLootButtonAlt = @(Get-ConfigValue $config @('ocrRegions', 'htLootButtonAlt') @(388, 489, 205, 86)) # 보조: 넓은 영역
$ptHtLootButton = @(452, 530)      # 클릭 지점: 두 배치(494~537 / 524~568) 모두 버튼 안 (실측)
# 결과 화면 (2026-07-17 실측): 던전(나가기/다시 하기)과 달리 '나가기/머무르기/새 임무 선택'
# 3버튼 구성이라 반복 재시작 버튼이 다릅니다 - '새 임무 선택'을 눌러야 첫 화면으로 돌아갑니다.
$rgHtRetryBtn  = @(Get-ConfigValue $config @('ocrRegions', 'htRetryButton') @(620, 625, 300, 60)) # '새 임무 선택' 버튼 글자 영역
$ptHtNewMission = @(797, 655)      # '새 임무 선택' 버튼 클릭 지점 (실측)
$ptHtClose      = @(1228, 67)      # 첫 화면 우상단 닫기(X) - 은동전 소진 시 나가기용 (실측)

# 진입 옵션 화면의 클릭 좌표 (기준 1272x717 실측)
$ptDgStageEnter   = @(918, 655)    # 선택 화면의 'N층 M구역 진입' 버튼
$ptDgBackArrow    = @(43, 67)      # 진입 옵션 화면 좌상단 '<' (선택 화면으로 한 단계 뒤로) - 2026-07-18 실측
                                   # 주의: ESC는 한 단계 뒤로가 아니라 던전 UI 전체를 닫고 필드로 나감 (18:44 실측)
$rgDgOptDifficulty = @(600, 95, 190, 50) # 진입 옵션 화면 상단 난이도 알약(일반/어려움) - 2026-07-18 실측
$ptDgCoinButton   = @(463, 313)    # 은동전(소탕) 카드의 선택됨/도전 버튼
$ptDgLootButton   = @(452, 517)    # 더블 루팅 카드의 선택됨/도전 버튼
$ptDgChanceToggle = @(1183, 415)   # '우연한 만남' 토글 (초록 = 켜짐)
$ptDgPartyFind    = @(775, 655)    # '파티 찾기' 버튼
$ptDgEnterFinal   = @(1015, 655)   # '입장하기' 버튼
# '던전에 입장하시겠습니까?' 확인 팝업 (도전 미수락 시 표시): '일주일 동안 보지 않기' 체크 후 입장
$rgDgWeekPopup    = @(Get-ConfigValue $config @('ocrRegions', 'dgWeekPopup') @(450, 520, 380, 60)) # '일주일 동안 보지 않기' 문구 영역
$ptDgConfirmEnter = @(742, 618)    # 확인 팝업의 '입장하기' 버튼
# 클리어 후 결과 화면의 버튼 구성 (2026-07-18 실측 - 스테이지/난이도에 따라 달라짐):
#   1-1/1-2/2-1/2-2      = 나가기 / 다시 하기 / 다음 구역으로   (3버튼)
#   1-3                  = 나가기 / 다시 하기 / 다음 층으로     (3버튼)
#   일반 2-3             = 나가기 / 다시 하기 / 다음 난이도로   (3버튼)
#   어려움(최종) 2-3     = 나가기 / 다시 하기                   (2버튼)
# 3버튼일 때 다시 하기는 가운데(637,655)로 이동합니다. 그래서 클릭은 고정 좌표가 아니라
# '다시 하기' 글자 탐색 지점을 쓰고('다음 ~로' 계열은 탐색어에 안 걸림), 영역은 두 배치를 모두 덮습니다.
$rgDgRetryBtn   = @(Get-ConfigValue $config @('ocrRegions', 'dgRetryButton') @(540, 625, 340, 60)) # '다시 하기' 버튼 영역 (두 배치 커버)
$ptDgRetry      = @(637, 655)      # '다시 하기' 예비 좌표 (글자 탐색 실패 시 - 3버튼 배치 기준)
$ptDgResultExit = @(515, 654)      # 결과 화면 '나가기' 버튼 (안전 중지 시 사용)
# 은동전 소탕 결과 화면: 전리품 공개(카드) 상태에서는 나가기/다시 하기가 아직 없고
# 화면을 한 번 클릭해야 진행됩니다. '발견한 전리품' 라벨로 이 상태를 감지합니다.
$rgDgLootReveal = @(Get-ConfigValue $config @('ocrRegions', 'dgLootReveal') @(520, 293, 240, 40))  # '발견한 전리품' 라벨 영역
# 우상단 재화 표시줄(골드 + 은동전): 마지막 숫자 그룹이 은동전 잔량입니다 (실측 검증됨)
$rgDgCoinBalance = @(Get-ConfigValue $config @('ocrRegions', 'dgCoinBalance') @(1040, 52, 225, 34))   # 2026-07-17 확장: 결과 화면은 재화 바가 우측 끝까지 밀려 175 폭으론 은동전 숫자가 잘림 (실측)
# '입장하기' 버튼의 공물(은동전) 소모량 표시: 소탕만 10 / 더블 루팅까지 20.
# 아이콘+'입장하기' 텍스트까지 함께 읽어야 숫자가 안정적으로 잡힘 (실측 검증됨).
# 하단 버튼이 '파티 찾기'+'입장하기' 2버튼 ↔ 넓은 단일 '입장하기'로 바뀌면 숫자 위치도
# 좌우로 움직이므로, 두 레이아웃을 모두 덮는 넓은 영역을 씁니다 (두 레이아웃 실측 검증됨)
$rgDgTributeCost = @(Get-ConfigValue $config @('ocrRegions', 'dgTributeCost') @(840, 636, 290, 44))

# 행동불능(사망) 자동 부활: 던전 클리어 대기 중 화면 중앙의 '남은 부활 횟수' 안내가
# 보이면(=행동불능 상태), 남은 횟수가 있을 때 R키(여기서 부활)를 눌러 전투를 이어갑니다.
$reviveEnabled     = [bool](Get-ConfigValue $config @('revive', 'enabled') $true)
$reviveKey         = [int](Get-ConfigValue $config @('revive', 'key') 82)    # 82 = R ('여기서 부활' 단축키)
$reviveMaxPerCycle = [int](Get-ConfigValue $config @('revive', 'maxPerCycle') 10)
# 부활 완료 후 전투를 다시 시작하는 키: 부활하면 자동전투가 꺼진 상태라 자동출발(Space)을
# 다시 눌러야 전투가 이어집니다. 0 을 넣으면 누르지 않습니다.
$reviveResumeKey   = [int](Get-ConfigValue $config @('revive', 'resumeKey') 32)   # 32 = Space
# 행동불능 안내 영역: '행동불능 / 부활 제한 구역입니다 / 남은 부활 횟수 N/M' 문구가 표시되는 화면 중앙
$rgDeathStatus     = @(Get-ConfigValue $config @('ocrRegions', 'deathStatus') @(500, 160, 290, 120))
# 남은 부활 횟수가 없을 때 클릭할 '여신상에서 부활' 버튼 위치(OCR 탐색 실패 시 예비 좌표)
$ptStatueRevive    = @(Get-ConfigValue $config @('clickPoints', 'statueRevive') @(968, 610))
# 부활 버튼들이 표시되는 우하단 영역: 버튼 배치가 남은 횟수에 따라 달라지므로
# 이 영역 안에서 '여신상' 글자를 OCR로 찾아 실제 위치를 클릭합니다.
$rgReviveButtons   = @(Get-ConfigValue $config @('ocrRegions', 'reviveButtons') @(700, 570, 555, 135))
# 우하단 자동사냥 버튼의 아이콘 중심 좌표(클릭용 아님, 상태 판별용).
# 꺼짐 = 나침반 아이콘(중심에 검은 점) / 켜짐 = 흰 사각형(정지 아이콘) → 픽셀로 구분합니다.
$ptAutoHuntIcon    = @(Get-ConfigValue $config @('clickPoints', 'autoHuntIcon') @(1192, 637))

$refocusEverySeconds = [int](Get-ConfigValue $config @('focus', 'refocusEverySeconds') 8)
$refocusIdleSeconds  = [int](Get-ConfigValue $config @('focus', 'onlyWhenUserIdleSeconds') 15)

$windowNormalize = [bool](Get-ConfigValue $config @('window', 'normalize') $true)
$windowMode      = [string](Get-ConfigValue $config @('window', 'mode') 'nearest')
$windowX         = [int](Get-ConfigValue $config @('window', 'x') 0)
$windowY         = [int](Get-ConfigValue $config @('window', 'y') 0)
$windowWidth     = [int](Get-ConfigValue $config @('window', 'width') 1908)
$windowHeight    = [int](Get-ConfigValue $config @('window', 'height') 1076)

$afterEntryDelayMs = [int](Get-ConfigValue $config @('afterEntry', 'keyDelayMs') 500)

# 입장 후 누를 키 목록을 해석합니다. 새 형식({key, label, enabled})과
# 예전 형식(숫자 목록 + keyLabels)을 모두 지원하며, enabled=false 인 키는 건너뜁니다.
$rawAfterEntryKeys = @(Get-ConfigValue $config @('afterEntry', 'keys') @())
$legacyKeyLabels   = @(Get-ConfigValue $config @('afterEntry', 'keyLabels') @('자동출발', '음식 자동 먹기'))
if ($rawAfterEntryKeys.Count -eq 0) {
  $rawAfterEntryKeys = @(
    [pscustomobject]@{ key = 32; label = '자동출발'; enabled = $true },
    [pscustomobject]@{ key = 66; label = '음식 자동 먹기'; enabled = $true }
  )
}

$afterEntryActions = @()
for ($entryIndex = 0; $entryIndex -lt $rawAfterEntryKeys.Count; $entryIndex++) {
  $entry = $rawAfterEntryKeys[$entryIndex]
  if ($entry -is [System.Management.Automation.PSCustomObject] -and $entry.PSObject.Properties['key']) {
    $entryEnabled = $true
    if ($entry.PSObject.Properties['enabled'] -and $null -ne $entry.enabled) {
      $entryEnabled = [bool]$entry.enabled
    }
    if (-not $entryEnabled) { continue }
    $entryLabel = '키 입력'
    if ($entry.PSObject.Properties['label'] -and $entry.label) { $entryLabel = [string]$entry.label }
    $afterEntryActions += @{ Key = [int]$entry.key; Label = $entryLabel }
  } else {
    $entryLabel = '키 입력'
    if ($entryIndex -lt $legacyKeyLabels.Count -and $legacyKeyLabels[$entryIndex]) {
      $entryLabel = [string]$legacyKeyLabels[$entryIndex]
    }
    $afterEntryActions += @{ Key = [int]$entry; Label = $entryLabel }
  }
}

$logDir = Join-Path $PSScriptRoot 'Log'
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir | Out-Null
}
$logPath = Join-Path $logDir 'mabinogi_run_once.log'
# 안전 중지 신호 파일: 컨트롤 패널에서 '안전 중지'를 누르면 생성됩니다.
# 이 파일이 있으면 던전에서 나와 밖(HUD)이 확인된 시점에서 회차를 조기 종료합니다.
$safeStopFlagPath = Join-Path $logDir 'safe_stop.flag'

# 원격 데스크톱 창 최소화 등으로 화면 캡처가 안 되는 동안 true가 되는 상태 플래그입니다.
# 이 동안에는 각 대기 단계의 제한 시간이 흐르지 않습니다(화면 복구 후 이어서 감지).
$script:screenCaptureFailing = $false
# 캡처 실패 중 마지막으로 안내한 원인 문구/원인 종류입니다. 실패 도중 원인이 바뀌면
# (예: 최소화 → RDP 연결 끊김) 새 원인을 한 번 더 안내하고, 복구 시에는 기억해 둔
# 원인에 맞춰 "어떻게 복구됐는지"(본체 전환/RDP 재개 등)를 로그에 남깁니다.
$script:captureFailMessage = $null
$script:captureFailCause = $null
# 캡처 실패가 '시작된 시각'입니다. 안전 중지 예약을 캡처 실패 대기 중에 소비하는 것은
# 실패가 충분히 오래(2분 이상) 지속되어 '영영 복구되지 않는 상황'으로 보일 때만 하기 위한 기준.
$script:captureFailingSince = $null
# 마지막으로 캡처에 성공했을 때의 세션 연결 이름입니다(예: 'rdp-tcp#3', 'console').
# RDP는 접속할 때마다 새 연결 이름이 되므로, 실패 시점에 이름이 바뀌어 있으면
# '창 최소화'(연결 유지, 이름 동일)가 아니라 'RDP 재접속 직후'로 판별합니다.
$script:lastGoodStationName = $null
# 현재 실행 중인 콘텐츠의 로그 접두어입니다. 공통 함수(클리어 대기, 토글 카드, 팝업 처리 등)의
# 로그가 어느 콘텐츠에서 나온 것인지 보이도록, 던전/사냥터 흐름 진입 시 각자 값으로 바꿉니다.
$script:contentTag = '[어비스]'

function Write-RunLog {
  param([string]$Message)
  # 날짜는 로그 맨 위 헤더에 한 번만 기록하고, 각 줄에는 시각만 붙입니다.
  $line = "$(Get-Date -Format 'HH:mm:ss') $Message"
  # 컨트롤러 등 다른 프로세스가 로그를 읽는 순간과 겹치면 쓰기가 잠깐 실패할 수 있습니다.
  # 로그 기록 실패로 자동화 전체가 죽지 않도록 짧게 재시도하고, 끝내 실패해도 진행을 계속합니다.
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
      break
    } catch {
      Start-Sleep -Milliseconds 50
    }
  }
  Write-Host $line
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
  $quotedScript = '"' + $PSCommandPath + '"'
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Normal -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $quotedScript
  )
  exit
}

# 중복 실행 방지: 이미 다른 자동화 인스턴스가 돌고 있으면 이 인스턴스는 바로 종료합니다.
# (컨트롤러 없이 떠도는 워커가 게임을 계속 조작하는 사고를 막습니다)
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Global\HoneyNogiRunOnce')
if (-not $script:instanceMutex.WaitOne(0)) {
  Write-RunLog '[중단] 이미 다른 자동화 인스턴스가 실행 중이라 이 실행을 취소합니다.'
  Write-Host '이미 다른 자동화가 실행 중입니다. 3초 후 이 창을 닫습니다.' -ForegroundColor Red
  Start-Sleep -Seconds 3
  exit 2
}

for ($attempt = 0; $attempt -lt 20; $attempt++) {
  try {
    Set-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd')] 자동화 로그 (시작 $(Get-Date -Format 'HH:mm:ss'))" -Encoding UTF8 -ErrorAction Stop
    break
  } catch {
    Start-Sleep -Milliseconds 50
  }
}
$Host.UI.RawUI.WindowTitle = '꿀비노기'
Write-Host '꿀비노기(마비노기 모바일 자동화)를 시작합니다.' -ForegroundColor Cyan
Write-Host '진행 상황은 이 창과 mabinogi_run_once.log에 기록됩니다.' -ForegroundColor DarkGray

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType=WindowsRuntime] | Out-Null
[Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null

$asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.IsGenericMethod -and
    $_.GetParameters().Count -eq 1
  } |
  Select-Object -First 1

$ocrKoreanLanguage = New-Object Windows.Globalization.Language('ko')
$ocrKoreanEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ocrKoreanLanguage)
$ocrEnglishLanguage = New-Object Windows.Globalization.Language('en-US')
$ocrEnglishEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ocrEnglishLanguage)

# 화면 감지가 전부 OCR 기반입니다. 한국어 OCR은 필수이고(감지 문구 대부분이 한국어),
# 영어 OCR은 Home/End/ESC 버튼 감지의 정확도를 높여 주는 선택 사항입니다 - 없어도
# 한국어 OCR이 영문을 읽을 수 있어(실측: 'HomeESC'로 판독됨) 그걸로 대체 진행합니다.
if (-not $ocrKoreanEngine) {
  # 한국어 OCR이 없는 드문 경우(한국어가 아닌 Windows)만 설치를 기다립니다.
  # dism.exe로 설치하면 출력에 진행률(%)이 찍히므로 10초마다 읽어 진행 로그를 남깁니다.
  # 종료 코드 3010 = 성공 + 재부팅 필요. 30분 넘으면 대기만 중단(설치는 백그라운드 계속).
  Write-RunLog '[준비] 한국어 OCR이 이 PC에 없습니다 - 자동 설치를 시작합니다 (보통 10~15분)'
  try {
    $dismOut = Join-Path $env:TEMP "mabinogi_ocr_install_$PID.log"
    $dismProc = Start-Process -FilePath 'dism.exe' `
      -ArgumentList @('/Online', '/Add-Capability', '/CapabilityName:Language.OCR~~~ko-KR~0.0.1.0', '/NoRestart') `
      -WindowStyle Hidden -PassThru -RedirectStandardOutput $dismOut
    $null = $dismProc.Handle   # Handle을 미리 캐시해야 종료 후 ExitCode를 읽을 수 있음 (PS 함정 - 실측)
    $elapsedSec = 0
    $lastLoggedPct = ''
    $lastLogSec = 0
    while (-not $dismProc.HasExited) {
      Start-Sleep -Seconds 10
      $elapsedSec += 10
      if ($elapsedSec -ge 1800) {
        # 30분 초과: dism 클라이언트는 중단하지만, 실제 설치(TrustedInstaller)는
        # 백그라운드에서 계속돼 나중에 완료되는 경우가 많습니다 (실측 확인).
        try { $dismProc.Kill() } catch { }
        throw '설치가 30분을 넘겨 대기를 중단했습니다 - Windows가 백그라운드에서 설치를 이어갈 수 있으니 10분쯤 뒤 [시작]을 다시 눌러 보세요'
      }
      # dism 출력 파일에서 마지막 진행률(%)을 읽습니다 (쓰는 중이라 공유 읽기로 열기)
      $pctText = ''
      try {
        # 읽기 도중 예외가 나도 핸들이 남지 않도록 finally 에서 해제합니다
        # (StreamReader.Dispose 가 내부 FileStream 까지 닫으므로 sr 우선, 없으면 fs)
        $fs = $null; $sr = $null
        try {
          $fs = New-Object System.IO.FileStream($dismOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
          $sr = New-Object System.IO.StreamReader($fs)
          $dismText = $sr.ReadToEnd()
        } finally {
          if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
        }
        $pctMatches = [regex]::Matches($dismText, '(\d{1,3}(?:\.\d)?)\s*%')
        if ($pctMatches.Count -gt 0) { $pctText = " $($pctMatches[$pctMatches.Count - 1].Groups[1].Value)%" }
      } catch { }
      # 진행률이 바뀌면 10초마다 바로 기록하고, 정체 중에는 60초마다만 기록해
      # 긴 설치에서 같은 줄이 수백 개 쌓이지 않게 합니다.
      if (-not $dismProc.HasExited) {
        if (($pctText -and $pctText -ne $lastLoggedPct) -or (($elapsedSec - $lastLogSec) -ge 60)) {
          Write-RunLog "[준비] 한국어 OCR 설치 진행 중...$pctText (경과 $([Math]::Floor($elapsedSec / 60))분 $($elapsedSec % 60)초)"
          $lastLoggedPct = $pctText
          $lastLogSec = $elapsedSec
        }
      }
    }
    $dismCode = $null
    try { $dismCode = $dismProc.ExitCode } catch { }
    if ($null -eq $dismCode) {
      # 종료 코드를 못 읽는 경우가 있어(실측), 실패로 단정하지 않고 아래의 엔진
      # 재생성 결과로 설치 성공 여부를 판정합니다.
      Write-RunLog '[준비] 한국어 OCR 설치 프로세스 종료 (코드 확인 불가 - 설치 여부는 이어서 확인합니다)'
    } elseif ($dismCode -eq 3010) {
      Write-RunLog '[준비] 한국어 OCR 설치 완료 (Windows가 재부팅을 요청했습니다 - 인식이 안 되면 재부팅 후 다시 실행하세요)'
    } elseif ($dismCode -eq 0) {
      Write-RunLog '[준비] 한국어 OCR 설치 완료'
    } else {
      # 실패 원인 진단용으로 dism 출력의 마지막 줄들을 함께 남깁니다
      $dismTail = ''
      try {
        $dismTail = ((Get-Content -LiteralPath $dismOut | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / ')
      } catch { }
      throw "dism 설치 실패 (종료 코드 $dismCode)$(if ($dismTail) { " - $dismTail" })"
    }
    Remove-Item -LiteralPath $dismOut -Force -ErrorAction SilentlyContinue
  } catch {
    Write-RunLog "[경고] 한국어 OCR 자동 설치 실패: $($_.Exception.Message)"
  }
  $ocrKoreanEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ocrKoreanLanguage)
}
if (-not $ocrKoreanEngine) {
  # (이 검사는 메인 try/catch 밖이라, 이유를 로그에 남기고 명시적으로 종료합니다)
  $installedOcr = ''
  try { $installedOcr = ([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }) -join ', ' } catch { }
  Write-RunLog "[오류] 한국어 OCR을 사용할 수 없습니다 $(if ($installedOcr) { "(설치된 OCR 언어: $installedOcr)" } else { '(설치된 OCR 언어 없음)' })"
  Write-RunLog "[안내] 방금 자동 설치가 진행됐다면 Windows가 백그라운드에서 마무리 중일 수 있습니다 - 5~10분 뒤 [시작]을 다시 눌러 보고, 그래도 안 되면 재부팅 후 다시 실행하세요"
  Write-RunLog "[안내] 자동 설치가 실패했다면(인터넷 없음 등): 설정 > 시간 및 언어 > 언어 및 지역 > '언어 추가'에서 '한국어'를 설치하세요"
  exit 1
}
if (-not $ocrEnglishEngine) {
  # 영어 OCR은 기다리지 않습니다: 백그라운드로 설치만 걸어 두고 이번 실행은 한국어
  # OCR로 대체해 바로 시작합니다 (설치가 끝나면 다음 실행부터 영어 OCR을 사용).
  # Windows가 같은 기능 설치를 직렬화하므로 여러 번 걸어도 실제 설치는 한 번만 됩니다.
  # 설치 상태를 확인해 상황에 맞는 안내를 남깁니다 (설치됨/진행 중/미설치 구분).
  try {
    $enCapState = $null
    try { $enCapState = [string](Get-WindowsCapability -Online -Name 'Language.OCR~~~en-US~0.0.1.0' -ErrorAction Stop).State } catch { }
    if ($enCapState -match 'Installed') {
      Write-RunLog '[준비] 영어 OCR 설치는 끝났지만 아직 반영 전입니다 (다음 실행 또는 재부팅 후 적용) - 이번 실행은 한국어 OCR로 대체해 진행합니다'
    } elseif (Get-Process -Name 'dism' -ErrorAction SilentlyContinue) {
      Write-RunLog '[준비] 영어 OCR 백그라운드 설치가 진행 중입니다 (중복 설치 아님) - 이번 실행은 한국어 OCR로 대체해 진행합니다'
    } else {
      Start-Process -FilePath 'dism.exe' `
        -ArgumentList @('/Online', '/Add-Capability', '/CapabilityName:Language.OCR~~~en-US~0.0.1.0', '/NoRestart') `
        -WindowStyle Hidden | Out-Null
      Write-RunLog '[준비] 영어 OCR이 없어 백그라운드 설치를 걸어 두고, 이번 실행은 한국어 OCR로 대체해 바로 진행합니다'
    }
  } catch {
    Write-RunLog '[준비] 영어 OCR이 없습니다 - 한국어 OCR로 대체해 진행합니다'
  }
  $ocrEnglishEngine = $ocrKoreanEngine
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HoneyNogiInput {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

  [DllImport("user32.dll")]
  public static extern bool ShowWindowAsync(IntPtr hWnd, int command);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();

  [DllImport("user32.dll")]
  public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

  [DllImport("user32.dll")]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

  [DllImport("user32.dll")]
  public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);

  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int index);

  [DllImport("user32.dll")]
  public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref RECT pvParam, uint fWinIni);

  [StructLayout(LayoutKind.Sequential)]
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

  [DllImport("user32.dll")]
  public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

  [DllImport("kernel32.dll")]
  public static extern uint GetTickCount();

  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint esFlags);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [DllImport("user32.dll")]
  public static extern IntPtr WindowFromPoint(POINT point);

  [DllImport("user32.dll")]
  public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

  [DllImport("wtsapi32.dll")]
  public static extern void WTSFreeMemory(IntPtr pMemory);
}
'@

# 디스플레이 배율(DPI) 대응: 창 좌표·클릭·캡처가 항상 "실제 픽셀"을 쓰도록 통일합니다.
# 모니터별 DPI 인식(V2)을 사용해야 실행 도중 배율이 바뀌어도(예: RDP 150% 세션이
# 본체 모니터 100%로 전환) 좌표계가 어긋나지 않습니다. 실패 시 구형 방식으로 폴백합니다.
$dpiContextSet = $false
try {
  $dpiContextSet = [HoneyNogiInput]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch { }
if (-not $dpiContextSet) {
  try {
    $threadContext = [HoneyNogiInput]::SetThreadDpiAwarenessContext([IntPtr](-4))
    $dpiContextSet = ($threadContext -ne [IntPtr]::Zero)
  } catch { }
}
if (-not $dpiContextSet) {
  [HoneyNogiInput]::SetProcessDPIAware() | Out-Null
}

# 화면 꺼짐/시스템 절전 방지: 감지가 화면 렌더링에 의존하므로, 자동화가 도는 동안
# 디스플레이가 꺼지지 않게 유지합니다. (원격 도구 접속을 끊은 뒤 유휴 시간으로
# 화면이 꺼지면서 캡처가 실패하는 것을 예방. 프로세스 종료 시 자동 해제됨)
# 2147483651 = 0x80000003 = ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
[HoneyNogiInput]::SetThreadExecutionState([uint32]2147483651) | Out-Null

function Get-GameProcess {
  # 프로세스가 아예 없으면 Get-Process가 먼저 예외를 던져 아래 한국어 안내가 묻히므로,
  # SilentlyContinue로 조회한 뒤 조치 방법이 담긴 메시지로 직접 알립니다.
  $process = Get-Process -Name 'MabinogiMobile' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1

  if (-not $process) {
    throw '마비노기 모바일 창을 찾지 못했습니다. 게임을 먼저 실행한 뒤 다시 시작해 주세요.'
  }
  return $process
}

function Get-UserIdleSeconds {
  # 사용자의 마지막 키보드/마우스 입력 이후 경과 시간(초)을 반환합니다.
  $info = New-Object HoneyNogiInput+LASTINPUTINFO
  $info.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($info)
  if (-not [HoneyNogiInput]::GetLastInputInfo([ref]$info)) {
    return [double]::MaxValue
  }
  $elapsedMs = [HoneyNogiInput]::GetTickCount() - $info.dwTime
  return [double]$elapsedMs / 1000.0
}

function Test-GameCovered {
  param([System.Diagnostics.Process]$Game)

  # 게임 창이 실제로 다른 창에 가려져 있는지 확인합니다.
  # 창 내부의 주요 지점(중앙, HUD 영역, 하단 문구 영역 등)에 어떤 창이 떠 있는지
  # WindowFromPoint 로 조사해서, 하나라도 게임이 아니면 "가려짐"으로 판단합니다.
  $gameHandle = $Game.MainWindowHandle
  if ([HoneyNogiInput]::IsIconic($gameHandle)) { return $true }

  $rect = New-Object HoneyNogiInput+RECT
  if (-not [HoneyNogiInput]::GetWindowRect($gameHandle, [ref]$rect)) { return $false }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { return $false }

  # 확인 지점: 중앙 / 우상단(HUD) / 하단 중앙(클리어 문구) / 좌측 중앙
  $probes = @(
    @(0.50, 0.50), @(0.78, 0.12), @(0.50, 0.85), @(0.25, 0.50)
  )
  foreach ($probe in $probes) {
    $point = New-Object HoneyNogiInput+POINT
    $point.X = $rect.Left + [int]($width * $probe[0])
    $point.Y = $rect.Top + [int]($height * $probe[1])
    $hitWindow = [HoneyNogiInput]::WindowFromPoint($point)
    if ($hitWindow -eq [IntPtr]::Zero) { return $true }
    $rootWindow = [HoneyNogiInput]::GetAncestor($hitWindow, 2)  # GA_ROOT
    if ($rootWindow -ne $gameHandle) { return $true }
  }
  return $false
}

function Invoke-AutoRefocus {
  param([System.Diagnostics.Process]$Game)

  # 게임 창이 "실제로 가려져 있을 때만" 앞으로 가져옵니다.
  # (가려지지 않았다면 아무것도 하지 않으므로 불필요한 포커스 이동이 없습니다)
  # 또한 사용자가 PC를 조작 중이면(최근 입력 있음) 포커스를 뺏지 않고 건너뜁니다.
  # config.json: focus.onlyWhenUserIdleSeconds (0 = 유휴 검사 없이 진행)
  if (-not (Test-GameCovered -Game $Game)) {
    return $false
  }
  if ($refocusIdleSeconds -gt 0 -and (Get-UserIdleSeconds) -lt $refocusIdleSeconds) {
    return $false
  }
  Focus-Game -Game $Game
  return $true
}

function Focus-Game {
  param([System.Diagnostics.Process]$Game)

  [HoneyNogiInput]::ShowWindowAsync($Game.MainWindowHandle, 9) | Out-Null
  [HoneyNogiInput]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [HoneyNogiInput]::SetForegroundWindow($Game.MainWindowHandle) | Out-Null
  Start-Sleep -Milliseconds 80
  [HoneyNogiInput]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 700
}

function Get-ScaledScreenPoint {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$ReferenceX,
    [int]$ReferenceY
  )

  $rect = New-Object HoneyNogiInput+RECT
  if (-not [HoneyNogiInput]::GetWindowRect($Game.MainWindowHandle, [ref]$rect)) {
    throw '게임 창 좌표를 읽지 못했습니다.'
  }

  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -lt 900 -or $height -lt 500) {
    throw "게임 창 크기가 너무 작습니다: ${width}x${height}"
  }

  return [System.Drawing.Point]::new(
    $rect.Left + [int][Math]::Round($ReferenceX * $width / $referenceWidth),
    $rect.Top + [int][Math]::Round($ReferenceY * $height / $referenceHeight)
  )
}

function Click-ScreenPoint {
  param([int]$X, [int]$Y)

  [HoneyNogiInput]::SetCursorPos($X, $Y) | Out-Null
  Start-Sleep -Milliseconds 250
  [HoneyNogiInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 100
  [HoneyNogiInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Click-GamePoint {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$ReferenceX,
    [int]$ReferenceY
  )

  $point = Get-ScaledScreenPoint -Game $Game -ReferenceX $ReferenceX -ReferenceY $ReferenceY
  Click-ScreenPoint -X $point.X -Y $point.Y
}

function Get-GamePixel {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$ReferenceX,
    [int]$ReferenceY
  )

  $point = Get-ScaledScreenPoint -Game $Game -ReferenceX $ReferenceX -ReferenceY $ReferenceY
  $bitmap = New-Object System.Drawing.Bitmap 1, 1
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, $bitmap.Size)
    return $bitmap.GetPixel(0, 0)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Invoke-OcrOnBitmap {
  param(
    [System.Drawing.Bitmap]$Bitmap,
    $Engine
  )

  # 비트맵을 임시 PNG 파일 없이 메모리에서 곧바로 WinRT OCR로 넘깁니다.
  # (기존 경로: 캡처 → PNG 저장 → 파일 열기 → 디코드 → OCR. 이 경로를 제거해 OCR 호출당
  #  디스크 쓰기 1회와 비동기 왕복 2회가 사라짐. 동등성 실측: 6개 조합 텍스트 동일, 약 2배 빠름)
  # Format32bppArgb 의 메모리 배치(B,G,R,A)는 WinRT Bgra8 과 같아 그대로 복사하면 됩니다.
  $lockRect = New-Object System.Drawing.Rectangle(0, 0, $Bitmap.Width, $Bitmap.Height)
  $bmpData = $Bitmap.LockBits($lockRect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $byteCount = $bmpData.Stride * $bmpData.Height
    $pixelBytes = New-Object byte[] $byteCount
    [System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $pixelBytes, 0, $byteCount)
  } finally {
    $Bitmap.UnlockBits($bmpData)
  }
  $buffer = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($pixelBytes, 0, $byteCount)
  $softwareBitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer($buffer, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, $Bitmap.Width, $Bitmap.Height)
  try {
    return (Await-WinRt ($Engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult]))
  } finally {
    $softwareBitmap.Dispose()
  }
}

function Await-WinRt {
  param($Operation, [Type]$ResultType)

  $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  $task.Wait()
  return $task.Result
}

function Get-SessionConnectState {
  # 자동화가 돌고 있는 현재 세션의 연결 상태를 조회합니다.
  # 반환값: 0 = Active(사용 중), 4 = Disconnected(RDP 연결 끊김) 등 / 조회 실패 시 -1.
  # (RDP 창 '최소화'는 세션이 여전히 Active이고, RDP '종료/끊김'은 Disconnected가 됩니다)
  $buffer = [IntPtr]::Zero
  $bytes = 0
  try {
    # -1 = WTS_CURRENT_SESSION(현재 세션), 8 = WTSConnectState
    if ([HoneyNogiInput]::WTSQuerySessionInformation([IntPtr]::Zero, -1, 8, [ref]$buffer, [ref]$bytes)) {
      return [System.Runtime.InteropServices.Marshal]::ReadInt32($buffer)
    }
    return -1
  } catch {
    return -1
  } finally {
    if ($buffer -ne [IntPtr]::Zero) { [HoneyNogiInput]::WTSFreeMemory($buffer) }
  }
}

function Get-SessionStationName {
  # 현재 세션의 연결 이름(예: 'rdp-tcp#3', 'console')을 조회합니다. 조회 실패 시 $null.
  $buffer = [IntPtr]::Zero
  $bytes = 0
  try {
    # -1 = WTS_CURRENT_SESSION(현재 세션), 6 = WTSWinStationName
    if ([HoneyNogiInput]::WTSQuerySessionInformation([IntPtr]::Zero, -1, 6, [ref]$buffer, [ref]$bytes)) {
      return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buffer)
    }
    return $null
  } catch {
    return $null
  } finally {
    if ($buffer -ne [IntPtr]::Zero) { [HoneyNogiInput]::WTSFreeMemory($buffer) }
  }
}

function Get-CaptureFailInfo {
  # 화면 캡처 실패의 원인을 세션 상태로 구분해, 원인 종류(Cause)와 안내 문구(Message)를 돌려줍니다.
  # Cause 는 복구 시 "어떻게 복구됐는지" 문구를 고르는 데도 사용됩니다.
  $state = Get-SessionConnectState
  if ($state -eq 4) {
    return @{
      Cause   = 'disconnected'
      Message = '[경고] 화면 캡처 실패 - RDP 연결이 끊긴 상태입니다. 본체 화면 자동 전환을 기다립니다 (조치 불필요, 보통 몇 초 내 자동 복구).'
    }
  }
  # 4096 = SM_REMOTESESSION: 0이 아니면 현재 RDP 세션에서 실행 중
  if ([HoneyNogiInput]::GetSystemMetrics(4096) -ne 0) {
    # 재접속이 빠르면 '끊김' 상태가 감지 주기 사이에 지나가 관측되지 않습니다.
    # 이때는 연결 이름 변화로 구분합니다: 최소화는 연결이 유지되어 이름이 그대로이고,
    # 재접속은 새 연결이라 이름이 바뀝니다(예: console → rdp-tcp#4).
    $station = Get-SessionStationName
    if ($script:lastGoodStationName -and $station -and $station -ne $script:lastGoodStationName) {
      return @{
        Cause   = 'reconnecting'
        Message = '[안내] RDP 재접속이 진행 중입니다. 잠시 후 자동으로 이어집니다.'
      }
    }
    return @{
      Cause   = 'minimized'
      Message = '[경고] 화면 캡처 실패 - RDP 창이 최소화된 것으로 보입니다. RDP 창을 다시 열어 주세요. 복구를 기다립니다.'
    }
  }
  return @{
    Cause   = 'other'
    Message = '[경고] 화면 캡처 실패 - 화면이 그려지지 않고 있습니다. 모니터 꺼짐/화면 잠금 여부를 확인해 주세요. 복구를 기다립니다.'
  }
}

function Get-CaptureRecoveryMessage {
  # 실패 원인과 '복구된 시점'의 세션 상태를 조합해, 어떻게 복구됐는지까지 안내합니다.
  # (예: RDP 종료 후 복구 = 본체 화면 전환 완료 / 최소화 후 복구 = RDP 창 다시 열림)
  param([string]$FailCause)

  $isRemoteNow = ([HoneyNogiInput]::GetSystemMetrics(4096) -ne 0)
  switch ($FailCause) {
    'disconnected' {
      if ($isRemoteNow) {
        return '[안내] RDP 재접속이 확인되어 화면 캡처가 복구됐습니다. 감지를 계속합니다.'
      }
      return '[안내] 본체 화면 자동 전환 완료 - 화면 캡처가 복구되어 감지를 계속합니다.'
    }
    'minimized' {
      if ($isRemoteNow) {
        return '[안내] RDP 창이 다시 열려 화면 캡처가 복구됐습니다. 감지를 계속합니다.'
      }
      # 최소화 경고 직후 사용자가 RDP를 닫아, 끊김 감지 전에 본체 전환까지 끝난 경우
      return '[안내] 본체 화면 자동 전환 완료 - 화면 캡처가 복구되어 감지를 계속합니다.'
    }
    'reconnecting' {
      return '[안내] RDP 재접속이 확인되어 화면 캡처가 복구됐습니다. 감지를 계속합니다.'
    }
    default {
      return '[안내] 화면 캡처가 복구되어 감지를 계속합니다.'
    }
  }
}

function Test-DesktopRenderingAlive {
  # 화면 렌더링이 실제로 살아 있는지 바탕화면 전체에서 띄엄띄엄 픽셀을 표본 조사합니다.
  # 게임의 OCR 영역이 전부 검을 때(던전 로딩 화면 등 '진짜 검은 장면'), 렌더링 중단
  # (RDP 최소화)과 구분하는 용도입니다. 로딩 화면이어도 작업표시줄/다른 창 등
  # 화면 어딘가에는 색이 있으므로, 표본에 색이 하나라도 있으면 렌더링은 정상입니다.
  $w = [HoneyNogiInput]::GetSystemMetrics(0)   # SM_CXSCREEN
  $h = [HoneyNogiInput]::GetSystemMetrics(1)   # SM_CYSCREEN
  if ($w -le 0 -or $h -le 0) { return $false }
  $bmp = New-Object System.Drawing.Bitmap 1, 1
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    foreach ($fx in 0.1, 0.5, 0.9) {
      foreach ($fy in 0.05, 0.5, 0.97) {
        $x = [int]($w * $fx)
        $y = [int]($h * $fy)
        try { $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size) } catch { continue }
        $c = $bmp.GetPixel(0, 0)
        if ($c.R -ne 0 -or $c.G -ne 0 -or $c.B -ne 0) { return $true }
      }
    }
    return $false
  } finally {
    $g.Dispose()
    $bmp.Dispose()
  }
}

function Test-BlankCapture {
  # 원격 데스크톱 창 최소화 등으로 화면이 그려지지 않으면, CopyFromScreen 이 예외 없이
  # '검게 비어 있는' 프레임을 돌려줄 때가 있습니다. 실제 게임 화면은 표본 픽셀이 전부
  # 순수 검정(0,0,0)일 수 없으므로, 그런 경우 '빈 캡처(=실패)'로 판단합니다.
  # (표본이 하나라도 검정이 아니면 정상 캡처로 보아, 정상 화면을 실패로 오판하지 않습니다.)
  param([System.Drawing.Bitmap]$Bitmap)

  $w = $Bitmap.Width
  $h = $Bitmap.Height
  if ($w -le 0 -or $h -le 0) { return $true }

  $stepX = [Math]::Max(1, [int]($w / 8))
  $stepY = [Math]::Max(1, [int]($h / 8))
  for ($y = 0; $y -lt $h; $y += $stepY) {
    for ($x = 0; $x -lt $w; $x += $stepX) {
      $c = $Bitmap.GetPixel($x, $y)
      if ($c.R -ne 0 -or $c.G -ne 0 -or $c.B -ne 0) {
        return $false
      }
    }
  }
  return $true
}

function Register-CaptureFailure {
  # 캡처 실패(예외/렌더링 멈춤)를 공용 상태로 기록합니다. 어떤 캡처 경로(영역 OCR,
  # 글자 위치 탐색)든 같은 상태를 공유해야 대기 루프의 '실패 중 시간 동결'이 정확히 동작합니다.
  # 경고는 실패가 '시작'될 때 한 번만 남기되, 원인을 세션 상태로 구분해 안내합니다
  # (RDP 연결 끊김 / RDP 창 최소화 / 그 외). 실패 도중 원인이 바뀌면 한 번 더 안내합니다.
  $failInfo = Get-CaptureFailInfo
  # 'RDP 끊김' 실패가 이어지던 중 세션이 다시 RDP 활성으로 바뀌면, 창 최소화가 아니라
  # 사용자가 RDP로 재접속하는 중입니다(끊김에서 RDP 활성으로 가는 경로는 재접속뿐).
  # 재접속 완료 직전 1~2초의 렌더링 공백을 '최소화'로 잘못 안내하지 않도록 구분합니다.
  if ($script:screenCaptureFailing -and
      ($script:captureFailCause -eq 'disconnected' -or $script:captureFailCause -eq 'reconnecting') -and
      $failInfo.Cause -eq 'minimized') {
    $failInfo = @{
      Cause   = 'reconnecting'
      Message = '[안내] RDP 재접속이 진행 중입니다. 잠시 후 자동으로 이어집니다.'
    }
  }
  if (-not $script:screenCaptureFailing) {
    # 이번 실패 구간이 언제 시작됐는지 기록 (안전 중지 조기 소비 판단 기준)
    $script:captureFailingSince = Get-Date
  }
  if (-not $script:screenCaptureFailing -or $failInfo.Message -ne $script:captureFailMessage) {
    $script:screenCaptureFailing = $true
    $script:captureFailMessage = $failInfo.Message
    $script:captureFailCause = $failInfo.Cause
    Write-RunLog $failInfo.Message
  }
}

function Register-CaptureSuccess {
  # 정상 캡처 성공을 공용 상태로 기록합니다. 실패 중이었다면 복구 로그를 남기고,
  # 세션 연결 이름을 추적해 끊김 없는 전환(RDP 재접속/본체 전환)도 한 줄 안내합니다.
  # (빈 화면으로 인한 헛복구/로그 반복을 막기 위해, 실제 정상 화면을 받은 경로에서만 호출)
  $justRecovered = $false
  if ($script:screenCaptureFailing) {
    $script:screenCaptureFailing = $false
    Write-RunLog (Get-CaptureRecoveryMessage -FailCause $script:captureFailCause)
    $script:captureFailMessage = $null
    $script:captureFailCause = $null
    $script:captureFailingSince = $null
    $justRecovered = $true
  }
  # 캡처 성공 시 현재 연결 이름을 기억해 둡니다. 다음 실패 때 이 이름과 비교해
  # '최소화'(이름 유지)와 'RDP 재접속'(이름 변경)을 구분하는 기준이 됩니다.
  # 또한 캡처가 한 번도 끊기지 않을 만큼 매끄럽게 세션이 전환된 경우에도(실패 로그 없음)
  # 전환 사실을 한 줄 남깁니다. 방금 복구 로그를 남겼다면 중복 안내는 생략합니다.
  $currentStation = Get-SessionStationName
  if (-not $justRecovered -and $script:lastGoodStationName -and $currentStation -and
      $currentStation -ne $script:lastGoodStationName) {
    if ($currentStation -like 'Console*') {
      Write-RunLog '[안내] 본체 화면 전환이 감지됐습니다 (캡처 중단 없음). 감지를 계속합니다.'
    } else {
      Write-RunLog '[안내] RDP 재접속이 감지됐습니다 (캡처 중단 없음). 감지를 계속합니다.'
    }
  }
  if ($currentStation) { $script:lastGoodStationName = $currentStation }
}

function Test-SafeStopDuringCaptureFail {
  # 캡처 실패로 대기가 길어지는 동안에도 '안전 중지' 예약을 확인합니다.
  # 화면이 영영 복구되지 않는 상황(RDP 미복구 등)에서도 사용자가 강제 종료 없이
  # 안전하게 끝낼 수단을 남기기 위한 것입니다.
  # 단, 짧은 순단(RDP 재접속 몇 초)에 발동하면 '회차 완료 후 중지'라는 안전 중지의
  # 원래 약속이 깨지므로, 실패가 2분 이상 이어질 때만 조기 종료합니다.
  if (-not (Test-Path -LiteralPath $safeStopFlagPath)) { return }
  if (-not $script:captureFailingSince) { return }
  if (((Get-Date) - $script:captureFailingSince).TotalSeconds -lt 120) { return }
  Remove-Item -LiteralPath $safeStopFlagPath -Force -ErrorAction SilentlyContinue
  Write-RunLog '[완료] 화면 캡처 실패가 2분 이상 지속 - 안전 중지 예약을 확인해 자동화를 마칩니다 (회차 미완료)'
  # 코드 0 이면 GUI/컨트롤러가 '회차 완료'로 세어 완료 횟수가 과다 계상되므로,
  # 던전을 끝내지 못한 이 경로는 '조건에 따른 정상 정지'(코드 4)로 종료합니다.
  exit 4
}

function Get-GameRegionOcrText {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$ReferenceX,
    [int]$ReferenceY,
    [int]$RegionWidth,
    [int]$RegionHeight,
    [int]$Scale = 3,
    $Engine = $ocrKoreanEngine,
    [switch]$BinaryWhiteText
  )

  $rect = New-Object HoneyNogiInput+RECT
  if (-not [HoneyNogiInput]::GetWindowRect($Game.MainWindowHandle, [ref]$rect)) {
    throw 'OCR용 게임 창 좌표를 읽지 못했습니다.'
  }

  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $cropLeft = $rect.Left + [int][Math]::Round($ReferenceX * $width / $referenceWidth)
  $cropTop = $rect.Top + [int][Math]::Round($ReferenceY * $height / $referenceHeight)
  $cropWidth = [int][Math]::Round($RegionWidth * $width / $referenceWidth)
  $cropHeight = [int][Math]::Round($RegionHeight * $height / $referenceHeight)
  $sourceCapture = New-Object System.Drawing.Bitmap $cropWidth, $cropHeight
  $sourceGraphics = [System.Drawing.Graphics]::FromImage($sourceCapture)
  $scaledCapture = New-Object System.Drawing.Bitmap ($RegionWidth * $Scale), ($RegionHeight * $Scale)
  $scaledGraphics = [System.Drawing.Graphics]::FromImage($scaledCapture)

  try {
    $captureFailed = $false
    try {
      $sourceGraphics.CopyFromScreen($cropLeft, $cropTop, 0, 0, $sourceCapture.Size)
    } catch {
      # 원격 데스크톱 창 최소화 등으로 화면 그리기가 멈추면 캡처가 예외로 실패합니다.
      $captureFailed = $true
    }
    # 예외가 없더라도 '검은(빈) 화면'만 돌아오는 경우가 있습니다(RDP 최소화 시 자주 발생).
    # 다만 던전 로딩 화면처럼 게임이 '진짜 검은 장면'을 보여주는 중일 수도 있으므로,
    # 바탕화면 전체 표본에 색이 하나도 없을 때만(=렌더링 자체가 멈춤) 실패로 처리합니다.
    if (-not $captureFailed -and (Test-BlankCapture -Bitmap $sourceCapture)) {
      if (-not (Test-DesktopRenderingAlive)) {
        $captureFailed = $true
      }
    }
    if ($captureFailed) {
      # 오류로 중단하지 않고 '글자를 못 읽은 상태'로 처리해, 화면이 복구되면 이어서 감지합니다.
      Register-CaptureFailure
      return ''
    }
    Register-CaptureSuccess

    if ($BinaryWhiteText) {
      for ($y = 0; $y -lt $cropHeight; $y++) {
        for ($x = 0; $x -lt $cropWidth; $x++) {
          $color = $sourceCapture.GetPixel($x, $y)
          if ($color.R -gt 175 -and $color.G -gt 175 -and $color.B -gt 175) {
            $sourceCapture.SetPixel($x, $y, [System.Drawing.Color]::Black)
          } else {
            $sourceCapture.SetPixel($x, $y, [System.Drawing.Color]::White)
          }
        }
      }
      $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    } else {
      $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    }

    $scaledGraphics.DrawImage(
      $sourceCapture,
      (New-Object System.Drawing.Rectangle 0, 0, ($RegionWidth * $Scale), ($RegionHeight * $Scale)),
      (New-Object System.Drawing.Rectangle 0, 0, $cropWidth, $cropHeight),
      [System.Drawing.GraphicsUnit]::Pixel
    )
    # 임시 PNG 파일 없이 메모리에서 곧바로 OCR (Invoke-OcrOnBitmap 주석 참고)
    return (Invoke-OcrOnBitmap -Bitmap $scaledCapture -Engine $Engine).Text
  } finally {
    $scaledGraphics.Dispose()
    $scaledCapture.Dispose()
    $sourceGraphics.Dispose()
    $sourceCapture.Dispose()
  }
}

function Get-GameOcrText {
  param([System.Diagnostics.Process]$Game)

  return Get-GameRegionOcrText -Game $Game -ReferenceX $rgClearExit[0] -ReferenceY $rgClearExit[1] `
    -RegionWidth $rgClearExit[2] -RegionHeight $rgClearExit[3] -Scale 3 -Engine $ocrKoreanEngine
}

function Find-GameTextPoint {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$ReferenceX,
    [int]$ReferenceY,
    [int]$RegionWidth,
    [int]$RegionHeight,
    [string]$SearchText,
    [string]$ExactText = '',
    [int]$Scale = 3,
    $Engine = $ocrKoreanEngine
  )

  # 영역을 OCR로 읽되 단어별 위치(BoundingRect)까지 받아, 찾는 글자가 포함된 단어의
  # 중심을 '화면 픽셀 좌표'로 돌려줍니다. 게임 UI가 상황에 따라 버튼 위치를 바꾸는 경우
  # (예: 부활 버튼 배치가 남은 횟수에 따라 달라짐) 고정 좌표 대신 이 함수로 찾아 클릭합니다.
  # ExactText 를 주면 '단어 전체가 정확히 일치'하는 것을 먼저 찾고, 없을 때만 SearchText
  # 부분 일치로 넘어갑니다. (예: '지옥1'과 '지옥10'처럼 이름이 겹치는 버튼 구분용)
  # 글자를 못 찾거나 캡처에 실패하면 $null 을 돌려줍니다.
  $rect = New-Object HoneyNogiInput+RECT
  if (-not [HoneyNogiInput]::GetWindowRect($Game.MainWindowHandle, [ref]$rect)) {
    return $null
  }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $cropLeft = $rect.Left + [int][Math]::Round($ReferenceX * $width / $referenceWidth)
  $cropTop = $rect.Top + [int][Math]::Round($ReferenceY * $height / $referenceHeight)
  $cropWidth = [int][Math]::Round($RegionWidth * $width / $referenceWidth)
  $cropHeight = [int][Math]::Round($RegionHeight * $height / $referenceHeight)
  $sourceCapture = New-Object System.Drawing.Bitmap $cropWidth, $cropHeight
  $sourceGraphics = [System.Drawing.Graphics]::FromImage($sourceCapture)
  $scaledCapture = New-Object System.Drawing.Bitmap ($RegionWidth * $Scale), ($RegionHeight * $Scale)
  $scaledGraphics = [System.Drawing.Graphics]::FromImage($scaledCapture)

  try {
    # 캡처 실패/빈 프레임 판정을 Get-GameRegionOcrText와 완전히 동일하게 공용 상태로 기록합니다.
    # (이 함수만 쓰는 대기 루프에서도 '실패 중 시간 동결'과 복구 감지가 동작해야 하기 때문)
    $captureFailed = $false
    try {
      $sourceGraphics.CopyFromScreen($cropLeft, $cropTop, 0, 0, $sourceCapture.Size)
    } catch {
      $captureFailed = $true
    }
    if (-not $captureFailed -and (Test-BlankCapture -Bitmap $sourceCapture)) {
      if (-not (Test-DesktopRenderingAlive)) {
        $captureFailed = $true
      }
    }
    if ($captureFailed) {
      Register-CaptureFailure
      return $null
    }
    Register-CaptureSuccess
    $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scaledGraphics.DrawImage(
      $sourceCapture,
      (New-Object System.Drawing.Rectangle 0, 0, ($RegionWidth * $Scale), ($RegionHeight * $Scale)),
      (New-Object System.Drawing.Rectangle 0, 0, $cropWidth, $cropHeight),
      [System.Drawing.GraphicsUnit]::Pixel
    )
    # 임시 PNG 파일 없이 메모리에서 곧바로 OCR (Invoke-OcrOnBitmap 주석 참고)
    $result = Invoke-OcrOnBitmap -Bitmap $scaledCapture -Engine $Engine
    $matchedWord = $null
    if ($ExactText) {
      # 1차: 단어 전체가 정확히 일치하는 것을 우선 채택 ('지옥1' vs '지옥10' 구분)
      foreach ($line in $result.Lines) {
        foreach ($word in $line.Words) {
          if (($word.Text -replace '\s', '') -eq $ExactText) { $matchedWord = $word; break }
        }
        if ($matchedWord) { break }
      }
    }
    if (-not $matchedWord) {
      # 2차: 찾는 글자가 포함된 첫 단어 (읽기 순서 = 왼쪽부터)
      foreach ($line in $result.Lines) {
        foreach ($word in $line.Words) {
          if (($word.Text -replace '\s', '').Contains($SearchText)) { $matchedWord = $word; break }
        }
        if ($matchedWord) { break }
      }
    }
    if ($matchedWord) {
      # 확대 이미지 좌표 -> 캡처 원본 픽셀 -> 화면 좌표로 역환산합니다.
      $centerXScaled = $matchedWord.BoundingRect.X + ($matchedWord.BoundingRect.Width / 2)
      $centerYScaled = $matchedWord.BoundingRect.Y + ($matchedWord.BoundingRect.Height / 2)
      $screenX = $cropLeft + [int][Math]::Round($centerXScaled * $cropWidth / ($RegionWidth * $Scale))
      $screenY = $cropTop + [int][Math]::Round($centerYScaled * $cropHeight / ($RegionHeight * $Scale))
      return [System.Drawing.Point]::new($screenX, $screenY)
    }
    return $null
  } finally {
    $scaledGraphics.Dispose()
    $scaledCapture.Dispose()
    $sourceGraphics.Dispose()
    $sourceCapture.Dispose()
  }
}

function Get-GameRegionOcrWords {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$ReferenceX,
    [int]$ReferenceY,
    [int]$RegionWidth,
    [int]$RegionHeight,
    [int]$Scale = 3,
    $Engine = $ocrKoreanEngine
  )

  # 영역을 한 번 OCR 해 모든 단어를 '기준 좌표(1272x717 환산)'와 함께 돌려줍니다.
  # 여러 라벨을 한 번에 읽어 위치를 비교할 때 사용합니다 (예: 던전 스테이지 지도 스크롤 보정).
  # 캡처 실패 시 빈 배열을 반환합니다.
  $rect = New-Object HoneyNogiInput+RECT
  if (-not [HoneyNogiInput]::GetWindowRect($Game.MainWindowHandle, [ref]$rect)) {
    return @()
  }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $cropLeft = $rect.Left + [int][Math]::Round($ReferenceX * $width / $referenceWidth)
  $cropTop = $rect.Top + [int][Math]::Round($ReferenceY * $height / $referenceHeight)
  $cropWidth = [int][Math]::Round($RegionWidth * $width / $referenceWidth)
  $cropHeight = [int][Math]::Round($RegionHeight * $height / $referenceHeight)
  $sourceCapture = New-Object System.Drawing.Bitmap $cropWidth, $cropHeight
  $sourceGraphics = [System.Drawing.Graphics]::FromImage($sourceCapture)
  $scaledCapture = New-Object System.Drawing.Bitmap ($RegionWidth * $Scale), ($RegionHeight * $Scale)
  $scaledGraphics = [System.Drawing.Graphics]::FromImage($scaledCapture)

  try {
    $captureFailed = $false
    try {
      $sourceGraphics.CopyFromScreen($cropLeft, $cropTop, 0, 0, $sourceCapture.Size)
    } catch {
      $captureFailed = $true
    }
    if (-not $captureFailed -and (Test-BlankCapture -Bitmap $sourceCapture)) {
      if (-not (Test-DesktopRenderingAlive)) {
        $captureFailed = $true
      }
    }
    if ($captureFailed) {
      Register-CaptureFailure
      return @()
    }
    Register-CaptureSuccess
    $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scaledGraphics.DrawImage(
      $sourceCapture,
      (New-Object System.Drawing.Rectangle 0, 0, ($RegionWidth * $Scale), ($RegionHeight * $Scale)),
      (New-Object System.Drawing.Rectangle 0, 0, $cropWidth, $cropHeight),
      [System.Drawing.GraphicsUnit]::Pixel
    )
    $result = Invoke-OcrOnBitmap -Bitmap $scaledCapture -Engine $Engine
    $words = @()
    foreach ($line in $result.Lines) {
      foreach ($word in $line.Words) {
        $centerXScaled = $word.BoundingRect.X + ($word.BoundingRect.Width / 2)
        $centerYScaled = $word.BoundingRect.Y + ($word.BoundingRect.Height / 2)
        # 확대 배율만 되돌리면 기준 좌표가 됩니다 (창 크기와 무관)
        $words += , @{
          Text = ($word.Text -replace '\s', '')
          X = $ReferenceX + [int][Math]::Round($centerXScaled / $Scale)
          Y = $ReferenceY + [int][Math]::Round($centerYScaled / $Scale)
        }
      }
    }
    # 주의: ,$words 로 감싸 반환하면 호출부의 @()가 '배열을 담은 1칸짜리 배열'로 만들어
    # foreach 가 단어가 아닌 배열 자체를 돌게 됩니다 (2026-07-18 18:07 실측 사고).
    # 그냥 반환해 파이프라인이 단어 단위로 풀게 하고, 호출부에서 @()로 모읍니다.
    return $words
  } finally {
    $scaledGraphics.Dispose()
    $scaledCapture.Dispose()
    $sourceGraphics.Dispose()
    $sourceCapture.Dispose()
  }
}

function Get-NdStageClickPoint {
  param([System.Diagnostics.Process]$Game, [string]$Stage)

  # 던전 스테이지 지도는 세로 스크롤 패널이라 노드 위치가 상태에 따라 위아래로 흐릅니다
  # (2026-07-18 17:50 실측 사고: 고정 좌표가 스크롤 상태에 따라 옆 노드에 떨어져
  # 1-2 대신 1-3이 선택됨). 매 시도마다 지도 라벨을 읽어 위치를 보정합니다:
  #  1) 원하는 스테이지 라벨(예: '1-2')이 읽히면 그 지점을 그대로 클릭 (라벨은 노드 안)
  #  2) 아니면 읽히는 다른 라벨/층 제목들로 세로 오프셋(현재 y - 기준 y)을 구해 보정
  #  3) 아무 라벨도 안 읽히면 기준 좌표 그대로 (이후 진입 버튼 문구 검증이 잡아줌)
  $basePoint = $ndStagePoints[$Stage]
  $mapWords = @(Get-GameRegionOcrWords -Game $Game -ReferenceX $rgNdStageMap[0] -ReferenceY $rgNdStageMap[1] `
      -RegionWidth $rgNdStageMap[2] -RegionHeight $rgNdStageMap[3] -Scale 3 -Engine $ocrKoreanEngine)
  $offsets = @()
  foreach ($mapWord in $mapWords) {
    if ($mapWord.Text -eq $Stage) {
      return @([int]$mapWord.X, [int]$mapWord.Y)
    }
    if ($ndMapAnchorY.ContainsKey($mapWord.Text)) {
      $offsets += ($mapWord.Y - $ndMapAnchorY[$mapWord.Text])
    }
  }
  if ($offsets.Count -gt 0) {
    $avgOffset = [int][Math]::Round(($offsets | Measure-Object -Average).Average)
    if ([Math]::Abs($avgOffset) -gt 8) {
      Write-RunLog "[던전] 스테이지 지도 스크롤 보정: 세로 ${avgOffset}px (라벨 $($offsets.Count)개 기준)"
    }
    return @([int]$basePoint[0], [int]($basePoint[1] + $avgOffset))
  }
  return $basePoint
}

function Get-EnterButtonText {
  param([System.Diagnostics.Process]$Game)

  # 상세 화면 하단 버튼 영역의 글자를 읽습니다. 캐릭터 위치에 따라
  # '입장하기'(던전 근처에 있음) 또는 '이동하기'(멀리 있어 이동 필요)가 표시됩니다.
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgEnterButton[0] -ReferenceY $rgEnterButton[1] `
    -RegionWidth $rgEnterButton[2] -RegionHeight $rgEnterButton[3] -Scale 4 -Engine $ocrKoreanEngine
  return ($ocrText -replace '\s', '')
}

function Test-DetailScreen {
  param([System.Diagnostics.Process]$Game)

  # 상세 화면 하단의 '입장하기' 버튼 글자로 '입장 가능한 상세 화면'인지 판단합니다.
  # (기존 픽셀 색 검사는 원격 데스크톱 등 환경에 따라 색이 조금 달라지면 어긋나므로 OCR로 대체)
  # OCR이 '입'을 깨뜨려도 살아남는 '장하'까지 함께 봅니다 ('이동하기'에는 없는 글자라 안전).
  return ((Get-EnterButtonText -Game $Game) -match '입장|장하')
}

function Test-PartyDetailScreen {
  param([System.Diagnostics.Process]$Game)

  # 함께하기 탭 화면인지 판단합니다. 하단이 '파티원 모집'+'입장하기' 2버튼 배치라
  # 입장하기 버튼이 혼자하기보다 오른쪽에 있어 전용 영역으로 읽습니다 (실측).
  $ocrText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgPartyEnterBtn[0] -ReferenceY $rgPartyEnterBtn[1] `
    -RegionWidth $rgPartyEnterBtn[2] -RegionHeight $rgPartyEnterBtn[3] -Scale 4 -Engine $ocrKoreanEngine) -replace '\s', ''
  return ($ocrText -match '입장|장하')
}

function Get-DetailTitleText {
  param([System.Diagnostics.Process]$Game)

  # 상세 화면 좌측 상단의 던전 이름 영역을 OCR로 읽습니다.
  # 제목은 혼자하기/함께하기 어느 탭에서든 항상 표시되므로,
  # '입장하기' 버튼(탭에 따라 위치가 바뀜)보다 안정적인 상세 화면 판별 기준입니다.
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgDetailTitle[0] -ReferenceY $rgDetailTitle[1] `
    -RegionWidth $rgDetailTitle[2] -RegionHeight $rgDetailTitle[3] -Scale 3 -Engine $ocrKoreanEngine
  return ($ocrText -replace '\s', '')
}

function Test-DetailTitleMatches {
  param([System.Diagnostics.Process]$Game)

  # 지금 열린 상세 화면이 "선택한 던전"의 것이 맞는지 확인합니다.
  # 1순위: 제목에 던전 키워드가 있으면 확정.
  # 2순위: 혼자하기 탭이 활성이면 좌상단 제목이 회색으로 흐려져 OCR이 실패할 수 있는데,
  #   이때 하단 '입장하기' 버튼이 읽히면 상세 화면에 도착한 것으로 인정합니다
  #   (다른 던전 상세로 잘못 들어간 경우는 시작 시 제목 검사에서 이미 걸러집니다).
  if ((Get-DetailTitleText -Game $Game).Contains($dungeonMatch)) { return $true }
  return (Test-DetailScreen -Game $Game)
}

function Test-DungeonEntered {
  param([System.Diagnostics.Process]$Game)

  # 던전 입장이 끝나면 우측 상단에 Home / End / ESC HUD가 나타납니다.
  # 이 HUD는 던전 선택/상세 화면에는 없고 게임플레이 화면에서만 보이므로,
  # 내용이 계속 바뀌는 퀘스트 추적기보다 훨씬 안정적인 입장 완료 신호입니다.
  return Test-HomeEndEscHud -Game $Game
}

function Wait-ForScreen {
  param(
    [scriptblock]$Condition,
    [int]$TimeoutSeconds,
    [string]$Description,
    [System.Diagnostics.Process]$Game,
    [int]$PollMilliseconds = 400
  )

  # 감지가 계속 실패하면(게임 창이 다른 창에 가려진 경우 등) 주기적으로 게임 창을
  # 다시 앞으로 가져와 감지를 복구합니다. config.json focus.refocusEverySeconds 로 조절(0=끄기).
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastFocus = Get-Date
  do {
    if (& $Condition) {
      return
    }
    if ($script:screenCaptureFailing) {
      # 화면 캡처가 안 되는 동안은 제한 시간을 멈춥니다(복구되면 남은 시간부터 다시 진행).
      # 복구가 영영 안 되는 상황에서도 안전하게 끝낼 수 있게 안전 중지 예약을 확인합니다.
      Test-SafeStopDuringCaptureFail
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    }
    if ($Game -and $refocusEverySeconds -gt 0 -and
        ((Get-Date) - $lastFocus).TotalSeconds -ge $refocusEverySeconds) {
      if (Invoke-AutoRefocus -Game $Game) { $lastFocus = Get-Date }
    }
    Start-Sleep -Milliseconds $PollMilliseconds
  } while ((Get-Date) -lt $deadline)

  throw "$Description 대기 시간이 초과됐습니다."
}

function Wait-ForDungeonClearScreen {
  param(
    [System.Diagnostics.Process]$Game,
    [int]$TimeoutSeconds = 300,
    [switch]$DungeonMode,
    [scriptblock]$FindResultButton
  )
  # DungeonMode: 던전/사냥터용. 어비스 전용 검사(나가기/어비스 선택 화면)를 건너뛰고
  # 폴링 간격을 1초로 줄여 클리어 화면을 더 빨리 감지합니다.
  # FindResultButton: 콘텐츠별 결과 화면 버튼 탐색(던전='다시 하기'/사냥터='새 임무 선택').
  # 사용자가 클리어 화면을 직접 터치해 이미 결과 화면으로 넘어간 경우를 잡습니다.

  # 반환값: 'clear' = 클리어 화면 감지 / 'reward' = 이미 보상 화면(사용자가 직접 터치해 넘긴 경우)
  #         'selection' = 이미 어비스 선택 화면(사용자가 끝까지 직접 진행한 경우)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastFocus = Get-Date
  $reviveCount = 0              # 이번 회차에 자동 부활한 횟수
  $reviveConfirmPending = $false # R키 입력 후 부활 완료 확인 대기 중
  $reviveBlockedLogged = $false  # 부활 불가 경고를 이미 남겼는지(반복 출력 방지)
  $autoHuntPresses = 0           # 자동사냥 꺼짐 감시가 자동출발 키를 누른 횟수(로그 정리용)
  $pollCounter = 0               # 팝업(2회)/컷신(3회) 확인 주기 조절용
  $useStatueRevive = $false      # 부활 재료 부족이 확인되면 이후 부활을 여신상으로 전환
  # 전투 진행 중 연장 한도: 제한 시간이 다 됐어도 퀘스트 추적기에 클리어 목표가 남아
  # 있으면(= 판이 길어진 것뿐) 오류 대신 대기를 연장하되, 이 절대 한도까지만 허용합니다.
  $extendLimit = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds * 3, 1800))
  $extendLogged = $false
  do {
    $pollCounter++

    # 클리어 감지가 목적이므로 가장 먼저, 매 바퀴 확인합니다 (지연 최소화)
    if (Test-DungeonClearPrompt -Game $Game) {
      Write-RunLog "$($script:contentTag) 클리어 문구(화면을 터치) 감지"
      return 'clear'
    }

    # 던전/사냥터: 사용자가 클리어 화면을 직접 터치해 이미 결과 화면으로 넘어간 경우 감지
    # (2026-07-18 21:52 실측: 18초 클리어 + 수동 터치 → 워커가 클리어 문구만 계속 대기하다
    #  시간 초과. 결과 화면에는 HUD가 없으므로, 전투 중 오탐 방지로 HUD 부재를 함께 확인)
    if ($FindResultButton -and ($pollCounter % 2) -eq 0 -and -not $script:screenCaptureFailing) {
      if ((& $FindResultButton) -and -not (Test-HomeEndEscHud -Game $Game)) {
        Write-RunLog "$($script:contentTag) 결과 화면 감지 (클리어 화면이 이미 지나감)"
        return 'reward'
      }
    }

    # 어비스 전용: 사용자가 직접 진행해 보상/선택 화면으로 넘어간 경우 감지 (던전 모드에서는 건너뜀)
    if (-not $DungeonMode) {
      # 사용자가 클리어 화면을 직접 터치해서 이미 보상 화면으로 넘어간 경우를 감지합니다.
      # (전투 중 채팅에 '나가기'가 지나가는 오탐을 막기 위해, HUD가 사라진 상태인지 함께 확인)
      if (Test-ExitButton -Game $Game) {
        if (-not (Test-HomeEndEscHud -Game $Game)) {
          Write-RunLog '[어비스] 보상 화면 감지 (클리어 화면이 이미 지나감)'
          return 'reward'
        }
      }

      # 사용자가 나가기까지 직접 눌러 어비스 선택 화면으로 돌아간 경우
      if (Test-AbyssSelectionScreen -Game $Game) {
        if (-not (Test-HomeEndEscHud -Game $Game)) {
          Write-RunLog '[어비스] 선택 화면 복귀 상태 감지 (직접 진행됨)'
          return 'selection'
        }
      }
    }

    # 구매 제안 팝업(회복 물약 부족 등)이 떠 있으면 화면 중앙을 덮어 감지가 가려지므로
    # '닫기'를 찾아 클릭합니다(부하를 줄이려고 2회 폴링마다 확인). 부활 시도 직후에 떴다면
    # 부활 재료(불사의 가루) 부족으로 판단하고 이후 부활은 여신상으로 전환합니다.
    if (($pollCounter % 2) -eq 0 -and -not $script:screenCaptureFailing) {
      $popupClosePoint = Find-GameTextPoint -Game $Game -ReferenceX $rgPopupClose[0] -ReferenceY $rgPopupClose[1] `
        -RegionWidth $rgPopupClose[2] -RegionHeight $rgPopupClose[3] -SearchText '닫기'
      if ($popupClosePoint) {
        Focus-Game -Game $Game
        Click-ScreenPoint -X $popupClosePoint.X -Y $popupClosePoint.Y
        if ($reviveConfirmPending) {
          $useStatueRevive = $true
          $reviveConfirmPending = $false
          Write-RunLog "$($script:contentTag) 부활 직후 구매 팝업(재료 부족 추정) - 닫고 이후 부활은 여신상으로 전환"
        } else {
          Write-RunLog "$($script:contentTag) 구매 팝업 감지 - 닫기 클릭"
        }
        Start-Sleep -Seconds 1
        continue
      }
    }

    # 행동불능(사망) 감지 시 자동 부활:
    #  - 남은 부활 횟수가 있으면 R키로 '여기서 부활' (그 자리에서 바로 전투 재개)
    #  - 남은 횟수가 없으면 '여신상에서 부활' 클릭 (여신상에서 살아나 전투를 이어감)
    if ($reviveEnabled) {
      $death = Get-DeathScreenInfo -Game $Game
      if ($death.Dead) {
        if ($reviveCount -ge $reviveMaxPerCycle) {
          if (-not $reviveBlockedLogged) {
            Write-RunLog "[경고] 이번 회차 자동 부활이 ${reviveMaxPerCycle}회에 도달해 더 시도하지 않습니다."
            $reviveBlockedLogged = $true
          }
        } elseif ($useStatueRevive -or ($null -ne $death.Remaining -and $death.Remaining -le 0)) {
          $reviveCount++
          $statueReason = if ($useStatueRevive) { '부활 재료 부족' } else { '남은 부활 횟수 없음' }
          Write-RunLog "$($script:contentTag) 행동불능($statueReason) - 여신상에서 부활 클릭"
          Focus-Game -Game $Game
          # 부활 버튼 배치는 남은 횟수 유무에 따라 달라지므로(0회면 버튼들이 한 줄로 재배치됨),
          # 고정 좌표 대신 '여신상' 글자를 OCR로 찾아 실제 버튼 위치를 클릭합니다.
          $statuePoint = Find-GameTextPoint -Game $Game -ReferenceX $rgReviveButtons[0] -ReferenceY $rgReviveButtons[1] `
            -RegionWidth $rgReviveButtons[2] -RegionHeight $rgReviveButtons[3] -SearchText '여신'
          if ($statuePoint) {
            Click-ScreenPoint -X $statuePoint.X -Y $statuePoint.Y
          } else {
            Write-RunLog '[경고] 여신상 부활 버튼 글자를 찾지 못해 예비 좌표를 클릭합니다'
            Click-GamePoint -Game $Game -ReferenceX $ptStatueRevive[0] -ReferenceY $ptStatueRevive[1]
          }
          $reviveConfirmPending = $true
          Start-Sleep -Seconds 3
          # 부활 후 전투가 이어지므로 클리어 제한 시간을 처음부터 다시 셉니다.
          $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
          continue
        } else {
          $reviveCount++
          $remainText = if ($null -ne $death.Remaining) { "남은 부활 횟수 $($death.Remaining)회" } else { '남은 횟수 인식 불가' }
          Write-RunLog "$($script:contentTag) 행동불능($remainText) - R키로 여기서 부활"
          Focus-Game -Game $Game
          Press-KeyOnce -VirtualKey ([byte]$reviveKey)
          $reviveConfirmPending = $true
          Start-Sleep -Seconds 3
          # 부활 후 전투가 이어지므로 클리어 제한 시간을 처음부터 다시 셉니다.
          $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
          continue
        }
      } elseif ($reviveConfirmPending) {
        $reviveConfirmPending = $false
        $reviveBlockedLogged = $false
        Write-RunLog "$($script:contentTag) 부활 완료 - 전투 계속"
      }

      # 자동사냥 꺼짐 상시 감시: 입장 키가 씹혔거나(그 순간 사용자가 마우스/키보드를 쓴 경우 등),
      # 부활 직후이거나, 어떤 이유로든 자동사냥이 꺼진 채 서 있으면 우하단에 나침반 아이콘(off)이
      # 보입니다. 그때만 자동출발 키를 눌러 다시 켭니다. 전투 중(스킬 버튼)이나 다른 화면에서는
      # 'unknown'으로 판정되어 아무것도 누르지 않으므로 안전합니다. resumeKey = 0 이면 감시를 끕니다.
      if ($reviveResumeKey -gt 0 -and -not $script:screenCaptureFailing) {
        $huntState = Get-AutoHuntState -Game $Game
        if ($huntState -eq 'off') {
          $autoHuntPresses++
          if ($autoHuntPresses -eq 1) {
            Write-RunLog "$($script:contentTag) 자동사냥 꺼짐 감지 - Space 재입력"
          } elseif (($autoHuntPresses % 15) -eq 0) {
            Write-RunLog "[경고] 자동출발 입력 ${autoHuntPresses}회째에도 자동사냥이 켜지지 않습니다 - 계속 시도합니다"
          }
          Focus-Game -Game $Game
          Press-KeyOnce -VirtualKey ([byte]$reviveResumeKey)
          Start-Sleep -Seconds 2
        } elseif ($huntState -eq 'on' -and $autoHuntPresses -gt 0) {
          Write-RunLog "$($script:contentTag) 자동사냥 켜짐 확인 (Space ${autoHuntPresses}회 입력)"
          $autoHuntPresses = 0
        }
      }
    }

    # 보스방 진입 컷신이 재생 중이면 '장면 넘기기' 버튼을 찾아 클릭해 바로 넘깁니다.
    # (부하를 줄이기 위해 3회 폴링마다 한 번씩만 확인)
    if (($pollCounter % 3) -eq 0 -and -not $script:screenCaptureFailing) {
      $skipSceneRegion = $rgCutsceneTop
      $skipScenePoint = Find-GameTextPoint -Game $Game -ReferenceX $rgCutsceneTop[0] -ReferenceY $rgCutsceneTop[1] `
        -RegionWidth $rgCutsceneTop[2] -RegionHeight $rgCutsceneTop[3] -SearchText '넘기'
      if (-not $skipScenePoint) {
        $skipSceneRegion = $rgCutsceneBottom
        $skipScenePoint = Find-GameTextPoint -Game $Game -ReferenceX $rgCutsceneBottom[0] -ReferenceY $rgCutsceneBottom[1] `
          -RegionWidth $rgCutsceneBottom[2] -RegionHeight $rgCutsceneBottom[3] -SearchText '넘기'
      }
      if ($skipScenePoint) {
        # 컷신이 그 사이에 저절로 끝났을 수 있으므로 클릭 직전에 한 번 더 확인합니다.
        # (끝난 뒤 그 자리를 누르면 클리어 화면을 건드리거나 미니맵이 열릴 수 있음)
        # 재확인은 '처음 찾았던 그 영역'을 다시 읽습니다 - 하단에서 찾고 상단을 재확인하면
        # 항상 무효화되어 하단 배치 컷신이 절대 스킵되지 않는 문제가 있었습니다.
        $skipScenePoint = Find-GameTextPoint -Game $Game -ReferenceX $skipSceneRegion[0] -ReferenceY $skipSceneRegion[1] `
          -RegionWidth $skipSceneRegion[2] -RegionHeight $skipSceneRegion[3] -SearchText '넘기'
      }
      if ($skipScenePoint) {
        Focus-Game -Game $Game
        Click-ScreenPoint -X $skipScenePoint.X -Y $skipScenePoint.Y
        Write-RunLog "$($script:contentTag) 컷신 - 장면 넘기기 클릭"
        Start-Sleep -Seconds 2
      }
    }

    if ($script:screenCaptureFailing) {
      # 원격 창 최소화 등으로 캡처가 안 되는 동안은 제한 시간을 멈춥니다.
      Test-SafeStopDuringCaptureFail
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    }
    # 게임 창이 가려져 있으면 OCR이 계속 실패하므로 주기적으로 게임을 앞으로 가져옵니다.
    if ($refocusEverySeconds -gt 0 -and
        ((Get-Date) - $lastFocus).TotalSeconds -ge $refocusEverySeconds) {
      if (Invoke-AutoRefocus -Game $Game) { $lastFocus = Get-Date }
    }
    # 던전 모드는 판이 짧아 감지 지연이 도드라지므로 폴링 간격을 절반(1초)으로 줄입니다
    Start-Sleep -Milliseconds $(if ($DungeonMode) { 1000 } else { 2000 })

    # 제한 시간이 다 됐어도 던전 안(퀘스트 추적기에 클리어 목표)이 확인되면 전투가 아직
    # 진행 중인 것이므로 오류로 끝내지 않고 60초씩 연장합니다 (다른 PC 실측 2026-07-17:
    # 어려움 파티전이 240초 한도를 넘겨 보스 15.2% 시점에 오류 종료된 사고).
    # 절대 한도($extendLimit)를 넘으면 전투가 아닌 다른 문제로 보고 기존처럼 오류 처리합니다.
    if ((Get-Date) -ge $deadline -and (Get-Date) -lt $extendLimit -and
        -not $script:screenCaptureFailing -and (Test-InDungeonQuest -Game $Game)) {
      if (-not $extendLogged) {
        Write-RunLog "$($script:contentTag) 클리어 대기 한도(${TimeoutSeconds}초)를 넘겼지만 전투가 아직 진행 중 - 끝날 때까지 연장 대기합니다"
        $extendLogged = $true
      }
      $deadline = (Get-Date).AddSeconds(60)
    }
  } while ((Get-Date) -lt $deadline)

  throw '던전 클리어 화면 감지 대기 시간이 초과됐습니다.'
}

function Get-AutoHuntState {
  param([System.Diagnostics.Process]$Game)

  # 우하단 자동사냥 버튼 아이콘을 픽셀 9곳(중심 5 + 반지름 10px 둘레 4)으로 판별합니다.
  #  - 'off' = 꺼짐(나침반): 중심 검은 바늘 축(실측 0,0,0) + 둘레는 흰 원(실측 255) → Space를 눌러도 되는 상태
  #  - 'on'  = 자동사냥 중(흰 사각형 정지 아이콘): 중심·둘레 모두 밝음 (실측 250+)
  #  - 'unknown' = 그 외. 전투 중에는 이 자리에 스킬 버튼이 떠서 나침반 패턴과 일치하지 않으며,
  #    이때 Space를 눌러도 게임이 받지 않으므로 '대기'로 처리해 헛입력을 막습니다.
  $centerOffsets = @(@(0, 0), @(-4, 0), @(4, 0), @(0, -4), @(0, 4))
  $ringOffsets = @(@(-10, 0), @(10, 0), @(0, -10), @(0, 10))
  $centerBright = 0
  $centerDark = 0
  $ringBright = 0
  foreach ($offset in $centerOffsets) {
    try {
      $color = Get-GamePixel -Game $Game -ReferenceX ($ptAutoHuntIcon[0] + $offset[0]) -ReferenceY ($ptAutoHuntIcon[1] + $offset[1])
    } catch {
      return 'unknown'
    }
    if ($color.R -gt 200 -and $color.G -gt 200 -and $color.B -gt 200) { $centerBright++ }
    elseif ($color.R -lt 100 -and $color.G -lt 100 -and $color.B -lt 100) { $centerDark++ }
  }
  foreach ($offset in $ringOffsets) {
    try {
      $color = Get-GamePixel -Game $Game -ReferenceX ($ptAutoHuntIcon[0] + $offset[0]) -ReferenceY ($ptAutoHuntIcon[1] + $offset[1])
    } catch {
      return 'unknown'
    }
    if ($color.R -gt 200 -and $color.G -gt 200 -and $color.B -gt 200) { $ringBright++ }
  }
  if ($centerBright -eq $centerOffsets.Count -and $ringBright -eq $ringOffsets.Count) { return 'on' }
  if ($centerDark -eq $centerOffsets.Count -and $ringBright -eq $ringOffsets.Count) { return 'off' }
  return 'unknown'
}

function Get-DeathScreenInfo {
  param([System.Diagnostics.Process]$Game)

  # 화면 중앙의 사망 안내 영역을 읽어 행동불능 여부와 남은 부활 횟수를 확인합니다.
  # 실측 결과 장식 폰트인 '행동불능' 글자는 OCR이 잘 못 읽지만, 그 아래
  # '남은 부활 횟수 3/3' 줄은 안정적으로 읽히므로 이 줄을 감지 기준으로 삼습니다.
  # 반환: @{ Dead = 사망 여부; Remaining = 남은 부활 횟수(파싱 실패 시 $null) }
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgDeathStatus[0] -ReferenceY $rgDeathStatus[1] `
    -RegionWidth $rgDeathStatus[2] -RegionHeight $rgDeathStatus[3] -Scale 3 -Engine $ocrKoreanEngine
  $normalized = $ocrText -replace '\s', ''
  $dead = (
    $normalized.Contains('남은부활') -or
    $normalized.Contains('부활횟수') -or
    $normalized.Contains('행동불능')
  )
  if (-not $dead) { return @{ Dead = $false; Remaining = $null } }
  $remaining = $null
  $match = [regex]::Match($normalized, '(\d+)/(\d+)')
  if ($match.Success) { $remaining = [int]$match.Groups[1].Value }
  return @{ Dead = $true; Remaining = $remaining }
}

function Test-DungeonClearPrompt {
  param([System.Diagnostics.Process]$Game)

  # 클리어 화면의 '화면을 터치해 주세요' 문구를 감지합니다.
  # 문구 뒤에 캐릭터가 겹치면 글자가 깨져 읽히는 경우가 있어 조합으로 느슨하게 확인합니다.
  # 실측된 깨짐 사례:
  #  - '화면을터夫6주' (2026-07-16: '치'가 깨짐)      → '화면을' + '터' 조합으로 잡음
  #  - '화n을터치해주l요' (2026-07-17: '면'이 깨짐)   → '터치해/터치하' 조각으로 잡음
  #  - '화면을치해주세요' (2026-07-18: '터'가 통째로 소실, 클리어 화면 2분 방치 실측)
  #    → '화면을' + '주세요' 조합으로 잡음
  # '화면을'이나 '터치'만 단독으로 쓰면 다른 안내와 겹칠 수 있어 두 조각 조합을 요구합니다.
  $ocrText = Get-GameOcrText -Game $Game
  $normalized = $ocrText -replace '\s', ''
  if ($normalized.Contains('화면을') -and $normalized.Contains('터')) { return $true }
  if ($normalized.Contains('화면을') -and $normalized.Contains('주세요')) { return $true }
  return ($normalized.Contains('터치해') -or $normalized.Contains('터치하'))
}

function Test-NoticeBoardPopup {
  param([System.Diagnostics.Process]$Game)

  # 공지 게시판 팝업(하단 탭: 공지사항/이벤트/쿠폰 입력/FAQ)을 감지합니다.
  # 아침 6시 리셋 뒤 이 팝업이 화면을 덮은 채 남으면, 가장자리로 필드 HUD가 그대로
  # 보여 '필드 상태'로 오판되고 ESC 클릭이 팝업에 막혀 무한 반복됩니다
  # (2026-07-19 06:42 hyodong 실측: ESC 클릭 18회 후 시간 초과).
  # 탭 줄 글자가 크고 또렷해 판독이 안정적입니다 ('공지사항'/'이벤트'/'쿠폰'/'FAQ').
  $text = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgNoticeTabs[0] -ReferenceY $rgNoticeTabs[1] `
    -RegionWidth $rgNoticeTabs[2] -RegionHeight $rgNoticeTabs[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
  if (-not $text) { return $false }
  if ($text.Contains('쿠폰')) { return $true }
  return ($text.Contains('공지') -and $text.Contains('이벤트'))
}

function Test-ExitButton {
  param([System.Diagnostics.Process]$Game)

  $ocrText = Get-GameOcrText -Game $Game
  $normalized = $ocrText -replace '\s', ''
  return $normalized.Contains('나가기')
}

function Test-HomeEndEscHud {
  param([System.Diagnostics.Process]$Game)

  # 게임플레이 화면 우측 상단의 Home / End / ESC 버튼을 감지합니다.
  # - 알림 아이콘이 끼면 배치가 밀리므로 Home~ESC가 모두 들어오는 넉넉한 영역을 사용합니다.
  # - 원격 데스크톱 압축 등으로 글자가 흐려질 수 있어 일반 OCR과 흰색 이진화 OCR 두 방식으로 읽고,
  #   세 단어(Home/End/ESC) 중 하나라도 확인되면 HUD가 있는 것으로 판단합니다.
  #   (선택/상세/클리어/보상 화면에서는 이 영역에 글자가 전혀 없어 오탐 위험이 없습니다.)
  $plainText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgHomeEndEsc[0] -ReferenceY $rgHomeEndEsc[1] `
    -RegionWidth $rgHomeEndEsc[2] -RegionHeight $rgHomeEndEsc[3] -Scale 5 -Engine $ocrEnglishEngine
  $normalized = ($plainText -replace '\s', '').ToLowerInvariant()
  if ($normalized.Contains('hom') -or $normalized.Contains('esc') -or $normalized.Contains('end')) {
    return $true
  }

  $binaryText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgHomeEndEsc[0] -ReferenceY $rgHomeEndEsc[1] `
    -RegionWidth $rgHomeEndEsc[2] -RegionHeight $rgHomeEndEsc[3] -Scale 5 -Engine $ocrEnglishEngine -BinaryWhiteText
  $normalized = ($binaryText -replace '\s', '').ToLowerInvariant()
  return ($normalized.Contains('hom') -or $normalized.Contains('esc') -or $normalized.Contains('end'))
}

function Test-MenuExitLabel {
  param([System.Diagnostics.Process]$Game)

  # ESC 메뉴 우하단의 '게임 종료' 문구를 확인합니다. 이 문구는 메뉴에서만 표시되므로
  # '메뉴가 열려 있다'는 독립적인 2차 신호로 씁니다 (두 창 크기에서 실측: '게임 종료' 정상 인식).
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgMenuExitLabel[0] -ReferenceY $rgMenuExitLabel[1] `
    -RegionWidth $rgMenuExitLabel[2] -RegionHeight $rgMenuExitLabel[3] -Scale 4 -Engine $ocrKoreanEngine
  return (($ocrText -replace '\s', '').Contains('종료'))
}

function Test-AbyssMenu {
  param([System.Diagnostics.Process]$Game)

  # 창이 작은 PC(예: 1368x771)에서는 메뉴 글자가 ~13px로 작아 OCR이 깨지기 쉽습니다
  # (실측: scale 3에서 '보스'→'니人' 등). 확대 배율을 4로 올리고,
  # '어비스'의 '어'가 깨져도 잡히도록 '비스' 조각까지 허용합니다
  # (이 메뉴 줄의 다른 글자(필드 보스/망령의 탑/레이드)와 겹치지 않음 - 실측 확인).
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgAbyssMenu[0] -ReferenceY $rgAbyssMenu[1] `
    -RegionWidth $rgAbyssMenu[2] -RegionHeight $rgAbyssMenu[3] -Scale 4 -Engine $ocrKoreanEngine
  $normalized = $ocrText -replace '\s', ''
  if ($normalized.Contains('어비스') -or $normalized.Contains('비스')) { return $true }
  # 2차 신호: 4번째 줄 글자가 통째로 깨지는 PC(OCR 엔진 차이)에서도 메뉴 열림을 놓치지 않게
  # 다른 위치의 메뉴 전용 문구('게임 종료')로 한 번 더 확인합니다.
  # (이 판정이 없으면 메뉴가 열린 채 공지사항의 'Home' 배지가 HUD로 오인되어
  #  ESC 위치를 재클릭 → 우편함이 열리는 사고가 남 - 2026-07-17 04:25 실측)
  return (Test-MenuExitLabel -Game $Game)
}

function Test-AbyssSelectionScreen {
  param([System.Diagnostics.Process]$Game)

  # 2026-07-16 UI 개편 대응: 좌상단 '어비스' 제목은 장식 폰트+아이콘 탓에 OCR이 불안정합니다
  # (실측: scale 3 '!힌 어비스' / scale 4 '0!切스' 로 깨짐). 우측 던전 배너 3장의 제목
  # (허상의 정박지/광기의 동굴/흩어진 물길)은 안정적으로 읽히므로 그쪽을 1차 기준으로 삼고,
  # 기존 제목 '비스' 검사는 보조 기준으로 유지합니다 (배너가 가려진 경우 대비).
  $cardsText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgAbyssCards[0] -ReferenceY $rgAbyssCards[1] `
    -RegionWidth $rgAbyssCards[2] -RegionHeight $rgAbyssCards[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
  foreach ($titleKeyword in $allDungeonKeywords) {
    if ($cardsText.Contains($titleKeyword)) { return $true }
  }
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgAbyssSelect[0] -ReferenceY $rgAbyssSelect[1] `
    -RegionWidth $rgAbyssSelect[2] -RegionHeight $rgAbyssSelect[3] -Scale 3 -Engine $ocrKoreanEngine
  $normalized = $ocrText -replace '\s', ''
  return $normalized.Contains('비스')
}

function Invoke-ClickUntil {
  param(
    [System.Diagnostics.Process]$Game,
    [int[]]$Point,
    [scriptblock]$Condition,
    [string]$Description,
    [int]$TimeoutSeconds = 20,
    [int]$ReclickEverySeconds = 5
  )

  # 클릭 후 목표 화면이 나타나는지 확인하고, 정해진 시간 동안 안 나오면 다시 클릭합니다.
  # 클릭이 빗나가거나 한 번에 반응하지 않아도 스스로 다시 시도합니다.
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    # 조건이 참이어도 캡처 실패 중이면 믿지 않습니다: 실패 중 OCR은 빈 문자열을 돌려주므로
    # '-not (화면 감지)' 형태의 부정형 조건이 클릭도 안 했는데 참이 되는 오판을 막습니다.
    if ((& $Condition) -and -not $script:screenCaptureFailing) { return }
    if ($script:screenCaptureFailing) {
      # 화면 캡처가 안 되는 동안은 결과 확인이 불가능하므로 클릭하지 않고 기다립니다.
      Test-SafeStopDuringCaptureFail
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
      Start-Sleep -Milliseconds 700
      continue
    }
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $Point[0] -ReferenceY $Point[1]
    $nextClick = (Get-Date).AddSeconds($ReclickEverySeconds)
    while ((Get-Date) -lt $nextClick -and (Get-Date) -lt $deadline) {
      if ((& $Condition) -and -not $script:screenCaptureFailing) { return }
      # 클릭 후 대기 중 캡처가 실패하면(RDP 끊김 등) 바깥 루프의 실패 처리로 나가
      # 제한 시간을 연장합니다 - 여기서 그냥 기다리면 실패 구간이 제한 시간을 소모해
      # 복구 직후 억울하게 초과되는 사고가 있었습니다 (2026-07-17 23:47 실측).
      if ($script:screenCaptureFailing) { break }
      Start-Sleep -Milliseconds 400
    }
  }
  throw "$Description 대기 시간이 초과됐습니다."
}

function Test-InDungeonQuest {
  param([System.Diagnostics.Process]$Game)

  # 던전 안에서는 우측 퀘스트 추적기 맨 위에 '<던전 이름> 클리어' 목표가 고정 표시됩니다.
  # 이 영역에 던전 키워드(정박/광기/물길...)가 보이면 '던전 안'으로 판정합니다.
  # (실측 검증: 던전 안 '허상의 정박지 클리어' → True / 필드 '[주간 목표]...' → False)
  $ocrText = Get-GameRegionOcrText -Game $Game -ReferenceX $rgQuestTracker[0] -ReferenceY $rgQuestTracker[1] `
    -RegionWidth $rgQuestTracker[2] -RegionHeight $rgQuestTracker[3] -Scale 3 -Engine $ocrKoreanEngine
  $normalized = $ocrText -replace '\s', ''
  foreach ($titleKeyword in $allDungeonKeywords) {
    if ($normalized.Contains($titleKeyword)) { return $true }
  }
  return $false
}

function Test-KnownScreen {
  param([System.Diagnostics.Process]$Game)

  # 자동화가 알고 있는 화면(어비스 선택 / 상세 / 던전 밖 HUD / 보상 / ESC 메뉴 /
  # 던전 선택·옵션 / 사냥터 첫 화면) 중 하나라도 감지되면 true.
  # 출석/이벤트 같은 전체 화면 오버레이 여부를 판단할 때 씁니다.
  if (Test-AbyssSelectionScreen -Game $Game) { return $true }
  if (Test-HomeEndEscHud -Game $Game) { return $true }
  if (Test-ExitButton -Game $Game) { return $true }
  if (Test-AbyssMenu -Game $Game) { return $true }
  $title = Get-DetailTitleText -Game $Game
  foreach ($titleKeyword in $allDungeonKeywords) {
    if ($title.Contains($titleKeyword)) { return $true }
  }
  # 던전 선택('~던전')/진입 옵션('N층 M구역') 화면 - 던전 카테고리도 이벤트 넘기기를 거치므로 필요
  $dgTitle = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
    -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
  if ($dgTitle.Contains('구역') -or $dgTitle.Contains('던전') -or $dgTitle.Contains('오드')) { return $true }
  # 사냥터 첫 화면 (하단 '입장하기'/'임무 시작' 버튼)
  if (Find-HtEntryButtonPoint -Game $Game) { return $true }
  # 사냥터 결과 화면 (나가기/머무르기/새 임무 선택) - 이걸 모르는 화면으로 보고 중앙을
  # 클릭하면 전리품 아이템 상세가 열릴 수 있어 알려진 화면으로 인식합니다 (2026-07-17 실측)
  if (Find-HtNewMissionPoint -Game $Game) { return $true }
  return $false
}

function Invoke-EventSkipOrConfirm {
  param(
    [System.Diagnostics.Process]$Game,
    [string]$LogPrefix = ''
  )

  # 출석/이벤트 화면의 '출석부 건너뛰기' 또는 보상 요약의 '확인' 버튼을 찾아 클릭합니다.
  # 클릭했으면 $true, 두 버튼 모두 없으면 $false 를 반환합니다.
  # (스텔라 픽/알 수 없는 화면 폴백은 시도 횟수 상태와 묶여 있어 여기에 포함하지 않습니다)
  $skipPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgEventSkip[0] -ReferenceY $rgEventSkip[1] `
    -RegionWidth $rgEventSkip[2] -RegionHeight $rgEventSkip[3] -SearchText '건너'
  if ($skipPoint) {
    Focus-Game -Game $Game
    Click-ScreenPoint -X $skipPoint.X -Y $skipPoint.Y
    Write-RunLog "[안내] ${LogPrefix}출석부 건너뛰기 클릭"
    Start-Sleep -Seconds 2
    return $true
  }
  # '출석 완료 - 우편으로 지원품이 지급되었습니다' 보상 화면: 하단 확인 버튼이 Space 조작이라
  # 클릭 대신 Space 를 눌러 넘깁니다 ('지원' 문구로 감지 - 실측 2026-07-17).
  $rewardText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgEventReward[0] -ReferenceY $rgEventReward[1] `
    -RegionWidth $rgEventReward[2] -RegionHeight $rgEventReward[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
  if ($rewardText.Contains('지원')) {
    Focus-Game -Game $Game
    Press-KeyOnce -VirtualKey ([byte]32)   # Space = 확인
    Write-RunLog "[안내] ${LogPrefix}출석 완료(지원품 지급) 화면 - Space로 확인"
    Start-Sleep -Seconds 2
    return $true
  }
  $confirmPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgEventConfirm[0] -ReferenceY $rgEventConfirm[1] `
    -RegionWidth $rgEventConfirm[2] -RegionHeight $rgEventConfirm[3] -SearchText '확인'
  if ($confirmPoint) {
    Focus-Game -Game $Game
    Click-ScreenPoint -X $confirmPoint.X -Y $confirmPoint.Y
    Write-RunLog "[안내] ${LogPrefix}보상 확인 클릭"
    Start-Sleep -Seconds 2
    return $true
  }
  return $false
}

function Clear-EventOverlay {
  param([System.Diagnostics.Process]$Game)

  # 아침 6시 리셋 후 뜨는 출석/이벤트 화면(전체 화면 NPC 장면)을 자동으로 넘깁니다.
  # 실측 흐름(2026-07-15): NPC 대화(중앙 클릭으로 진행) → 출석부 1~N개 연쇄
  # ('출석부 건너뛰기' 클릭) → '출석 완료' 보상 요약('확인' 클릭, 보상은 우편 지급) → 복귀.
  # 알려진 화면이 이미 보이면 아무것도 하지 않고 false, 넘기기를 수행했으면 true 반환.
  if (Test-KnownScreen -Game $Game) { return $false }

  Write-RunLog '[안내] 출석/이벤트 화면 추정 - 자동으로 넘깁니다'
  # 캡처 실패 중에는 시도 횟수를 소모하지 않습니다 (다른 대기 루프의 '시간 동결'과 동일한 원칙).
  # 아래(루프 끝)의 Test-KnownScreen OCR이 복구 탐침을 겸하므로 복구되면 자연히 이어집니다.
  # 시도 상한 20회: 아침 리셋 체인이 길 수 있습니다
  # (NPC 대화 여러 줄 + 출석부 + 출석 완료 + 스텔라 픽 2단계 + 공지 팝업들 - 실측 기준 여유 포함)
  $attempt = 0
  $maxAttempts = 20
  $stellaPicks = 0   # '오늘의 스텔라 픽' 카드 선택 시도 횟수 (2회 후에는 닫기 X로 전환)
  while ($attempt -lt $maxAttempts) {
    if ($script:screenCaptureFailing) {
      Test-SafeStopDuringCaptureFail
      Start-Sleep -Seconds 2
    } else {
      $attempt++
      # 0) '오늘의 스텔라 픽' 데일리 팝업(카드 3장 선택 - 실측 2026-07-16):
      #    좌상단 제목으로 감지해 가운데 카드를 골라 진행하고, 두 번 골라도 화면이
      #    남아 있으면(선택 불가 상태 등) 우상단 닫기(X)를 눌러 닫습니다.
      $stellaTitle = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgStellaTitle[0] -ReferenceY $rgStellaTitle[1] `
        -RegionWidth $rgStellaTitle[2] -RegionHeight $rgStellaTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
      if ($stellaTitle.Contains('스텔라')) {
        Focus-Game -Game $Game
        if ($stellaPicks -lt 2) {
          $stellaPicks++
          Click-GamePoint -Game $Game -ReferenceX $ptStellaCard[0] -ReferenceY $ptStellaCard[1]
          Write-RunLog '[안내] 오늘의 스텔라 픽 감지 - 가운데 카드 선택'
        } else {
          Click-GamePoint -Game $Game -ReferenceX $ptStellaClose[0] -ReferenceY $ptStellaClose[1]
          Write-RunLog '[안내] 스텔라 픽 화면이 남아 있어 닫기(X) 클릭'
        }
        Start-Sleep -Seconds 2
      } elseif ($stellaPickBtn = Find-GameTextPoint -Game $Game -ReferenceX $rgStellaPickBtn[0] -ReferenceY $rgStellaPickBtn[1] `
          -RegionWidth $rgStellaPickBtn[2] -RegionHeight $rgStellaPickBtn[3] -SearchText '스텔라') {
        # 스텔라 픽 2단계(확정 화면 - 실측 2026-07-17): 1단계에서 카드를 고르면 카드 캐러셀과
        # 하단 초록 '스텔라 픽' 확정 버튼이 나옵니다. 버튼을 눌러 오늘의 픽을 확정합니다.
        Focus-Game -Game $Game
        Click-ScreenPoint -X $stellaPickBtn.X -Y $stellaPickBtn.Y
        Write-RunLog '[안내] 스텔라 픽 2단계 - 확정 버튼(스텔라 픽) 클릭'
        Start-Sleep -Seconds 2
      } elseif ($todayOffBtn = Find-GameTextPoint -Game $Game -ReferenceX $rgEventTodayOff[0] -ReferenceY $rgEventTodayOff[1] `
          -RegionWidth $rgEventTodayOff[2] -RegionHeight $rgEventTodayOff[3] -SearchText '그만') {
        # 공지 팝업(점검/안내 - 실측 2026-07-17): '오늘 그만 보기'를 눌러 닫으면
        # 오늘 다시 뜨지 않습니다. 안내 문구의 '확인할...'을 확인 버튼으로 오인해
        # 헛클릭을 반복하지 않도록 이 검사가 '확인' 탐색보다 먼저 옵니다.
        Focus-Game -Game $Game
        Click-ScreenPoint -X $todayOffBtn.X -Y $todayOffBtn.Y
        Write-RunLog "[안내] 공지 팝업 - '오늘 그만 보기' 클릭"
        Start-Sleep -Seconds 2
      } elseif ($eventCloseBtn = Find-GameTextPoint -Game $Game -ReferenceX $rgEventCloseBtn[0] -ReferenceY $rgEventCloseBtn[1] `
          -RegionWidth $rgEventCloseBtn[2] -RegionHeight $rgEventCloseBtn[3] -SearchText '닫기') {
        # 새 이벤트 안내 팝업('닫기'/'이벤트 바로가기' 배치): 닫기를 눌러 넘어갑니다
        Focus-Game -Game $Game
        Click-ScreenPoint -X $eventCloseBtn.X -Y $eventCloseBtn.Y
        Write-RunLog "[안내] 이벤트 안내 팝업 - '닫기' 클릭"
        Start-Sleep -Seconds 2
      } elseif (Find-GameTextPoint -Game $Game -ReferenceX $rgNoticeBoardTabs[0] -ReferenceY $rgNoticeBoardTabs[1] `
          -RegionWidth $rgNoticeBoardTabs[2] -RegionHeight $rgNoticeBoardTabs[3] -SearchText '쿠폰') {
        # 웹뷰형 공지 보드(공지사항/이벤트/쿠폰 입력/FAQ 탭 - 실측 2026-07-17):
        # 텍스트 버튼이 없어 팝업 우상단 X(1090,137)로 닫습니다. 중앙 클릭 폴백이
        # 프로모션 썸네일을 눌러 다른 화면을 열지 않도록 폴백보다 먼저 처리합니다.
        Focus-Game -Game $Game
        Click-GamePoint -Game $Game -ReferenceX $ptNoticeBoardClose[0] -ReferenceY $ptNoticeBoardClose[1]
        Write-RunLog '[안내] 공지 보드 팝업 - 우상단 닫기(X) 클릭'
        Start-Sleep -Seconds 2
      } elseif (-not (Invoke-EventSkipOrConfirm -Game $Game)) {
        # 건너뛰기/확인 버튼이 둘 다 없는 화면. 처리 우선순위:
        # 1) 말풍선에 글자가 보이면 NPC 대화(알리사 도입 장면 등)로 보고 중앙 클릭으로 진행
        #    (대화가 길 수 있어 15회차까지 허용 - 실측 2026-07-17)
        # 2) 초반(1~5회)에는 말풍선이 없어도 NPC 장면 전환 중일 수 있어 중앙 클릭
        # 3) 후반(6회부터)에는 전체 화면 UI(인벤토리 등)로 보고 알려진 닫기(X) 위치를 순환 클릭
        #    (실측 2026-07-16~17: 화면 우상단/웹뷰 공지 보드/중앙 공지 팝업)
        # 어떤 시도든 로그를 남겨 '조용히 헤매는' 상황을 없앱니다.
        $bubbleText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgNpcDialogue[0] -ReferenceY $rgNpcDialogue[1] `
          -RegionWidth $rgNpcDialogue[2] -RegionHeight $rgNpcDialogue[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
        Focus-Game -Game $Game
        if ($bubbleText.Length -ge 2 -and $attempt -lt 15) {
          Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
          Write-RunLog "[안내] NPC 대화 진행 - 중앙 클릭 ($attempt/$maxAttempts)"
        } elseif ($attempt -ge 6) {
          $xCandidates = @(@(1229, 67), @(1090, 137), @(959, 180))
          $xPick = $xCandidates[($attempt - 6) % $xCandidates.Count]
          Click-GamePoint -Game $Game -ReferenceX $xPick[0] -ReferenceY $xPick[1]
          Write-RunLog "[안내] 알 수 없는 화면 - 닫기(X) 후보($($xPick[0]),$($xPick[1])) 클릭 시도 ($attempt/$maxAttempts)"
        } else {
          Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
          Write-RunLog "[안내] 알 수 없는 화면 - 중앙 클릭으로 진행 시도 ($attempt/$maxAttempts)"
        }
        Start-Sleep -Seconds 2
      }
    }
    if (Test-KnownScreen -Game $Game) {
      Write-RunLog '[안내] 이벤트 화면을 지나 원래 화면으로 복귀했습니다'
      return $true
    }
  }
  Write-RunLog '[경고] 이벤트 화면 자동 넘기기가 끝나지 않았습니다 - 그대로 진행합니다 (오류 시 Log의 스크린샷 확인)'
  return $true
}

function Resolve-DgEnterConfirmPopup {
  param([System.Diagnostics.Process]$Game)

  # '던전에 입장하시겠습니까?' 확인 팝업(도전 미수락 시 표시)이 떠 있으면
  # '일주일 동안 보지 않기'를 체크한 뒤 팝업의 입장하기를 눌러 진행합니다.
  # 팝업이 없으면 아무것도 하지 않고 false 를 돌려줍니다.
  $weekPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgDgWeekPopup[0] -ReferenceY $rgDgWeekPopup[1] `
    -RegionWidth $rgDgWeekPopup[2] -RegionHeight $rgDgWeekPopup[3] -Scale 4 -SearchText '일주일'
  if (-not $weekPoint) { return $false }
  # 체크박스는 '일주일' 글자 바로 왼쪽에 있습니다 (기준 좌표로 40px, 창 크기에 맞춰 환산)
  $rectWeek = New-Object HoneyNogiInput+RECT
  [HoneyNogiInput]::GetWindowRect($Game.MainWindowHandle, [ref]$rectWeek) | Out-Null
  $checkOffset = [int][Math]::Round(40 * ($rectWeek.Right - $rectWeek.Left) / $referenceWidth)
  Focus-Game -Game $Game
  Click-ScreenPoint -X ($weekPoint.X - $checkOffset) -Y $weekPoint.Y
  Write-RunLog "$($script:contentTag) 입장 확인 팝업 - '일주일 동안 보지 않기' 체크"
  Start-Sleep -Milliseconds 600
  Focus-Game -Game $Game
  Click-GamePoint -Game $Game -ReferenceX $ptDgConfirmEnter[0] -ReferenceY $ptDgConfirmEnter[1]
  Write-RunLog "$($script:contentTag) 입장 확인 팝업 - 입장하기 클릭"
  Start-Sleep -Milliseconds 1000
  return $true
}

function Get-DgCoinBalance {
  param([System.Diagnostics.Process]$Game)

  # 우상단 재화 표시줄을 읽어 은동전 잔량을 얻습니다. 골드 뒤의 마지막 숫자 그룹이
  # 은동전입니다 (은동전 아이콘이 '0'으로 붙어 '026'처럼 읽혀도 정수 변환으로 정리됨).
  # 읽기 실패 시 $null 을 돌려주고, 호출한 쪽에서 '알 수 없음'으로 처리합니다.
  $text = Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgCoinBalance[0] -ReferenceY $rgDgCoinBalance[1] `
    -RegionWidth $rgDgCoinBalance[2] -RegionHeight $rgDgCoinBalance[3] -Scale 4 -Engine $ocrKoreanEngine
  # 금화 자릿수 구분(쉼표, OCR이 마침표로 읽기도 함)을 먼저 제거합니다.
  # 안 그러면 '10,994,078'이 [10][994][078]로 쪼개져 금화 조각이 '마지막 그룹'이 되고,
  # 은동전 숫자가 영역 밖으로 잘린 화면에서 그 조각을 잔량으로 오인합니다 (실측 재현: 잔량 0 오판).
  $cleaned = $text -replace '[,\.]', ''
  $numberGroups = [regex]::Matches($cleaned, '\d+')
  if ($numberGroups.Count -eq 0) { return $null }
  $lastGroup = $numberGroups[$numberGroups.Count - 1].Value
  # 6자리 초과면 은동전이 아니라 금화가 병합된 것(은동전 숫자가 안 읽힘)이므로 실패 처리
  if ($lastGroup.Length -gt 6) { return $null }
  $value = [int]$lastGroup
  if ($value -gt 99999) { return $null }
  return $value
}

function Get-DgTributeCost {
  param([System.Diagnostics.Process]$Game)

  # '입장하기' 버튼에 표시되는 공물(은동전) 소모량을 읽습니다. 소탕만이면 10,
  # 더블 루팅까지면 20입니다. 숫자만 좁게 자르면 고립 숫자라 OCR이 실패해서
  # 아이콘+'입장하기' 텍스트까지 함께 읽고 숫자 그룹만 뽑습니다. 10/20 중 하나가
  # 잡히면 우선 그 값을, 아니면 마지막 숫자 그룹을 돌려줍니다. 실패 시 $null.
  # 숫자가 한 번에 안 잡히는 경우가 있어 스케일/엔진을 바꿔가며 재시도합니다.
  $attempts = @(
    @{ Scale = 3; Engine = $ocrKoreanEngine },
    @{ Scale = 5; Engine = $ocrKoreanEngine },
    @{ Scale = 3; Engine = $ocrEnglishEngine },
    @{ Scale = 5; Engine = $ocrEnglishEngine }
  )
  $fallbackValue = $null
  foreach ($attempt in $attempts) {
    $text = Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTributeCost[0] -ReferenceY $rgDgTributeCost[1] `
      -RegionWidth $rgDgTributeCost[2] -RegionHeight $rgDgTributeCost[3] -Scale $attempt.Scale -Engine $attempt.Engine
    $numberGroups = [regex]::Matches($text, '\d+')
    if ($numberGroups.Count -eq 0) { continue }
    foreach ($grp in $numberGroups) {
      $n = [int]$grp.Value
      if ($n -eq 10 -or $n -eq 20) { return $n }
    }
    # 유효값(10/20)은 아니지만 숫자는 읽힌 경우: 첫 성공 읽기를 예비로 보관
    if ($null -eq $fallbackValue) { $fallbackValue = [int]$numberGroups[$numberGroups.Count - 1].Value }
  }
  return $fallbackValue
}

function Find-DgRetryButtonPoint {
  param([System.Diagnostics.Process]$Game)

  # 결과 화면의 '다시 하기' 버튼을 찾습니다. OCR이 '다시'를 '다셔'로 깨뜨리거나
  # 기본 배율(3)에서는 '하기'만 읽는 경우가 있어(실측) 배율 5로 여러 후보를 찾습니다.
  # ('하기'는 이 영역에 다시 하기 버튼 글자만 들어와 안전 - 나가기는 영역 밖 + '가기')
  foreach ($searchWord in @('다시', '다셔', '하기')) {
    $point = Find-GameTextPoint -Game $Game -ReferenceX $rgDgRetryBtn[0] -ReferenceY $rgDgRetryBtn[1] `
      -RegionWidth $rgDgRetryBtn[2] -RegionHeight $rgDgRetryBtn[3] -SearchText $searchWord -Scale 5
    if ($point) { return $point }
  }
  return $null
}

function Find-HtNewMissionPoint {
  param([System.Diagnostics.Process]$Game)

  # 사냥터 결과 화면의 '새 임무 선택' 버튼을 찾습니다 (2026-07-17 실측: 던전과 달리
  # 나가기/머무르기/새 임무 선택 3버튼). 같은 영역의 '머무르기'/'나가기'에는 없는
  # '임무' 글자를 우선 찾고, OCR 깨짐 대비로 '선택'도 후보로 봅니다.
  foreach ($searchWord in @('임무', '선택')) {
    $point = Find-GameTextPoint -Game $Game -ReferenceX $rgHtRetryBtn[0] -ReferenceY $rgHtRetryBtn[1] `
      -RegionWidth $rgHtRetryBtn[2] -RegionHeight $rgHtRetryBtn[3] -SearchText $searchWord -Scale 5
    if ($point) { return $point }
  }
  return $null
}

function Exit-HuntingGroundExhausted {
  param([System.Diagnostics.Process]$Game, [string]$Reason)

  # 은동전 소진 시 사냥터를 완전히 벗어나고 자동화를 마칩니다 (사용자 결정 2026-07-18).
  # 첫 화면이면 X로 닫는데, 첫 화면이 결과 화면 위에 열려 있던 경우('새 임무 선택' 경유)
  # X를 닫으면 밑의 결과 화면이 다시 나오므로(2026-07-18 01:05 실측) 결과 화면이
  # 보이면 나가기 버튼까지 눌러 사냥터 밖(필드)으로 나갑니다.
  Write-RunLog "[완료] $Reason - 사냥터에서 나가고 자동화를 마칩니다"
  if (Find-HtEntryButtonPoint -Game $Game) {
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ptHtClose[0] -ReferenceY $ptHtClose[1]
    Start-Sleep -Seconds 2
  }
  if (Find-HtNewMissionPoint -Game $Game) {
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ptDgResultExit[0] -ReferenceY $ptDgResultExit[1]
    Write-RunLog '[사냥터] 결과 화면 나가기 클릭 (사냥터 밖으로)'
    Start-Sleep -Seconds 2
  }
  exit 4
}

function Find-HtEntryButtonPoint {
  param([System.Diagnostics.Process]$Game)

  # 사냥터 첫 화면 하단 우측 버튼을 찾습니다. 첫 진입 때는 '(은동전 10) 입장하기'인데,
  # '새 임무 선택'으로 복귀하면 다음 임무가 자동 선택되며 '(은동전 10) 임무 시작'으로
  # 바뀝니다 (2026-07-18 00:01 실측 - '입장'만 찾다 복귀를 인식 못 한 사고).
  # '시작'이 OCR에서 깨질 수 있어('ÅI즈' 실측) 같은 버튼의 '임무'도 후보로 봅니다.
  # (결과 화면에는 이 영역에 아무 버튼도 없어 '임무' 오탐 없음 - 실측 확인)
  foreach ($searchWord in @('입장', '임무', '시작')) {
    $point = Find-GameTextPoint -Game $Game -ReferenceX $rgHtEnterBtn[0] -ReferenceY $rgHtEnterBtn[1] `
      -RegionWidth $rgHtEnterBtn[2] -RegionHeight $rgHtEnterBtn[3] -SearchText $searchWord
    if ($point) { return $point }
  }
  return $null
}

# ===== 어비스/던전/사냥터 공통 블록 (2026-07-18 기술 부채 정리: 복사 코드 → 헬퍼 통일) =====

function Invoke-AfterEntryKeys {
  param([System.Diagnostics.Process]$Game, [string]$LogPrefix)

  # 입장 직후 키 입력: config.json 의 afterEntry.keys 중 enabled 인 키만 순서대로 한 번씩
  # 입력합니다 (예: 음식 자동 먹기(B)를 끄려면 해당 항목의 enabled 를 false 로).
  # 어비스 본류/파티원/던전/사냥터 네 흐름이 같은 동작을 씁니다.
  Focus-Game -Game $Game
  for ($keyIndex = 0; $keyIndex -lt $afterEntryActions.Count; $keyIndex++) {
    if ($keyIndex -gt 0) { Start-Sleep -Milliseconds $afterEntryDelayMs }
    $action = $afterEntryActions[$keyIndex]
    Press-KeyOnce -VirtualKey ([byte]$action.Key)
    Write-RunLog ("{0} {1} ({2} 키 입력완료)" -f $LogPrefix, $action.Label, (Get-KeyDisplayName $action.Key))
  }
}

function Wait-ForResultScreen {
  param(
    [System.Diagnostics.Process]$Game,
    [scriptblock]$FindRetryButton,
    [string]$MissingMessage
  )

  # 클리어 터치 후 엔딩 컷신을 넘기며 결과 화면을 기다립니다 (던전/사냥터 공통).
  #  - 컷신 '장면 넘기기' 클릭 (탐색이 캡처 상태 탐침을 겸함 - 실패 중에는 제한 시간 동결)
  #  - 클리어 터치가 등급 연출에 무시된 경우 '화면을 터치'가 남아 있으면 재터치
  #  - 은동전 소탕의 전리품 공개 화면은 '발견한 전리품' 라벨 지점 클릭으로 진행
  #    (라벨은 카드/버튼이 아니라 어디를 눌러도 진행만 되는 안전한 지점)
  # 반환: 반복 버튼 지점(던전 = 다시 하기 / 사냥터 = 새 임무 선택). 못 찾으면 throw.
  $resultDeadline = (Get-Date).AddSeconds(90)
  $retryPoint = $null
  while ((Get-Date) -lt $resultDeadline) {
    $skipScene = Find-GameTextPoint -Game $Game -ReferenceX $rgCutsceneTop[0] -ReferenceY $rgCutsceneTop[1] `
      -RegionWidth $rgCutsceneTop[2] -RegionHeight $rgCutsceneTop[3] -SearchText '넘기'
    if ($script:screenCaptureFailing) {
      Test-SafeStopDuringCaptureFail
      $resultDeadline = (Get-Date).AddSeconds(90)
      Start-Sleep -Seconds 2
      continue
    }
    if ($skipScene) {
      # 컷신이 그 사이 끝났을 수 있으므로 클릭 직전에 한 번 더 확인 (스테일 클릭 방지)
      $skipScene = Find-GameTextPoint -Game $Game -ReferenceX $rgCutsceneTop[0] -ReferenceY $rgCutsceneTop[1] `
        -RegionWidth $rgCutsceneTop[2] -RegionHeight $rgCutsceneTop[3] -SearchText '넘기'
    }
    if ($skipScene) {
      Focus-Game -Game $Game
      Click-ScreenPoint -X $skipScene.X -Y $skipScene.Y
      Write-RunLog "$($script:contentTag) 컷신 - 장면 넘기기 클릭"
      Start-Sleep -Seconds 2
      continue
    }
    if (Test-DungeonClearPrompt -Game $Game) {
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
      Write-RunLog "$($script:contentTag) 클리어 화면이 남아 있어 다시 터치"
      Start-Sleep -Seconds 2
      continue
    }
    $retryPoint = & $FindRetryButton
    if ($retryPoint) { break }

    $lootLabelPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgDgLootReveal[0] -ReferenceY $rgDgLootReveal[1] `
      -RegionWidth $rgDgLootReveal[2] -RegionHeight $rgDgLootReveal[3] -SearchText '발견'
    if ($lootLabelPoint) {
      Focus-Game -Game $Game
      # 라벨 지점을 그대로 클릭하면 게임 커서가 라벨 위에 주차돼 다음 폴링부터 OCR이
      # 라벨을 못 읽어 진행 클릭이 멈춥니다 (2026-07-19 08:26 실측: '발견한전'으로 판독,
      # 82초 방치 후 시간 초과). 어디를 눌러도 진행되는 화면이므로 라벨/카드에서 떨어진
      # 빈 배경(400,300)을 클릭해 커서가 감지를 가리지 않게 합니다.
      # 탐색어도 '발견' 조각으로 완화 (다른 요인으로 라벨 일부가 가려져도 감지 유지).
      Click-GamePoint -Game $Game -ReferenceX 400 -ReferenceY 300
      Write-RunLog "$($script:contentTag) 전리품 공개 화면 - 화면 클릭으로 진행"
      Start-Sleep -Seconds 2
      continue
    }
    Start-Sleep -Seconds 2
  }
  if (-not $retryPoint) { throw $MissingMessage }
  return $retryPoint
}

function Invoke-SafeStopExitIfRequested {
  param([System.Diagnostics.Process]$Game)

  # 결과 화면에서 안전 중지 예약이 있으면 나가기를 눌러 회차를 마칩니다 (던전/사냥터 공통).
  # 신호 파일은 워커가 소비(삭제)합니다 - GUI가 강제 종료되어 파일이 남아도
  # 다음 실행이 시작하자마자 헛되이 조기 종료되는 일이 없게 하기 위함입니다.
  if (-not (Test-Path -LiteralPath $safeStopFlagPath)) { return }
  Remove-Item -LiteralPath $safeStopFlagPath -Force -ErrorAction SilentlyContinue
  Focus-Game -Game $Game
  Click-GamePoint -Game $Game -ReferenceX $ptDgResultExit[0] -ReferenceY $ptDgResultExit[1]
  Write-RunLog '[완료] 안전 중지 예약 확인 - 결과 화면에서 나가기를 눌러 회차를 마칩니다'
  Start-Sleep -Seconds 2
  exit 0
}

function Get-ChanceToggleState {
  param(
    [System.Diagnostics.Process]$Game,
    [int[]]$Point
  )

  # '우연한 만남' 토글 상태를 픽셀로 판별합니다 (던전/어비스 공용 - 같은 위젯).
  # 켜짐이면 토글 왼쪽이 초록색(실측 13,179,118)이고, 꺼짐이면 회색이라 초록이 전혀 없습니다.
  # 반환: 'on' / 'off' / 'unknown'
  # 'unknown' = 픽셀을 못 읽었거나 표본이 전부 검정(RDP 최소화 중 빈 프레임)인 경우.
  # 빈 프레임을 '꺼짐'으로 단정하면 켜져 있던 토글을 블라인드 클릭으로 꺼버릴 수 있어 구분합니다.
  $blackSamples = 0
  $totalSamples = 0
  foreach ($offset in @(-11, 0, 7)) {
    try {
      $color = Get-GamePixel -Game $Game -ReferenceX ($Point[0] + $offset) -ReferenceY $Point[1]
    } catch {
      return 'unknown'
    }
    $totalSamples++
    if ($color.G -gt 150 -and $color.G -gt ($color.R + 80) -and $color.B -lt $color.G) { return 'on' }
    if (([int]$color.R + [int]$color.G + [int]$color.B) -lt 45) { $blackSamples++ }
  }
  if ($totalSamples -gt 0 -and $blackSamples -eq $totalSamples) { return 'unknown' }
  return 'off'
}

function Test-DifficultySelectedAt {
  param(
    [System.Diagnostics.Process]$Game,
    [System.Drawing.Point]$ScreenPoint
  )

  # 난이도 알약이 '선택됨' 상태인지 픽셀로 확인합니다. 선택된 알약에는 채도 높은 밝은
  # 테두리가 생기고(실측 2026-07-17: 입문=보라, 어려움=금색 239,174,66, 매우 어려움/지옥=빨강),
  # 선택 안 된 알약은 어두운 배경 + 흰 글자뿐입니다. 글자 중심 기준 위아래 테두리 지점
  # (dy≈±16)을 좁은 폭(dx≈±12)으로 표본 조사해, '밝고 채도 높은' 픽셀이 3개 이상이면 선택.
  #  - 흰 글자(채도 낮음)·어두운 비선택 배경은 안 걸림
  #  - dx 를 좁게 잡아 옆 알약 테두리 침범을 방지 (실측: 어려움 선택 시 6/18, 비선택은 0/18)
  $rect = New-Object HoneyNogiInput+RECT
  if (-not [HoneyNogiInput]::GetWindowRect($Game.MainWindowHandle, [ref]$rect)) { return $false }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { return $false }
  $refX = [int][Math]::Round(($ScreenPoint.X - $rect.Left) * $referenceWidth / $width)
  $refY = [int][Math]::Round(($ScreenPoint.Y - $rect.Top) * $referenceHeight / $height)
  $hits = 0
  foreach ($dy in @(-18, -16, -14, 14, 16, 18)) {
    foreach ($dx in @(-12, 0, 12)) {
      try {
        $c = Get-GamePixel -Game $Game -ReferenceX ($refX + $dx) -ReferenceY ($refY + $dy)
      } catch { continue }
      $chMax = [Math]::Max([int]$c.R, [Math]::Max([int]$c.G, [int]$c.B))
      $chMin = [Math]::Min([int]$c.R, [Math]::Min([int]$c.G, [int]$c.B))
      if ($chMax -gt 150 -and ($chMax - $chMin) -gt 60) { $hits++ }
    }
  }
  return ($hits -ge 3)
}

function Confirm-DifficultySelected {
  param(
    [System.Diagnostics.Process]$Game,
    [System.Drawing.Point]$ClickPoint,   # 첫 난이도 클릭에 성공한 '정확한' 좌표
    [string]$Label
  )

  # 난이도 클릭 '사후 검증': 클릭이 빗나가 다른 난이도로 바뀌는 사고를 막습니다.
  # 재클릭은 반드시 '첫 클릭과 같은 좌표'로만 합니다. OCR로 난이도를 다시 찾으면
  # '어려움'을 찾을 때 '매우 어려움'의 '어려움' 조각을 잡아 엉뚱한 난이도를 누르는
  # 사고가 나기 때문입니다 (실측 2026-07-17: 어려움 재클릭이 매우 어려움으로 감).
  # 선택 강조가 확인 안 되면 같은 자리를 1회 다시 누르고, 그래도 안 되면 경고만 남깁니다.
  for ($tryNo = 1; $tryNo -le 2; $tryNo++) {
    if (Test-DifficultySelectedAt -Game $Game -ScreenPoint $ClickPoint) {
      if ($tryNo -gt 1) { Write-RunLog "$($script:contentTag) 난이도 '$Label' 재클릭으로 선택 확인" }
      return $true
    }
    if ($tryNo -lt 2) {
      Focus-Game -Game $Game
      Click-ScreenPoint -X $ClickPoint.X -Y $ClickPoint.Y
      Start-Sleep -Milliseconds 800
    }
  }
  Write-RunLog "[경고] 난이도 '$Label' 선택 강조를 확인하지 못했습니다 - 현재 상태로 진행합니다"
  return $false
}

function Test-TabSelectedAt {
  param(
    [System.Diagnostics.Process]$Game,
    [int[]]$Point
  )

  # 상세 화면의 입장 방식 탭(혼자하기/함께하기)이 선택 상태인지 확인합니다.
  # 선택된 탭은 배경이 채도 높은 밝은 색으로 채워지고(혼자하기=청록, 함께하기=보라 -
  # 실측 2026-07-17: 선택 5/8, 비선택 0/8), 선택 안 된 탭은 어둡습니다.
  # 탭 글자 주변 배경을 표본 조사해 '밝고 채도 높은' 픽셀이 2개 이상이면 선택으로 판단합니다.
  # (dx를 좌우로 벌려 흰 글자를 피하고, 두 탭 사이 중앙의 장식 아이콘과 겹치지 않는 범위)
  $hits = 0
  foreach ($dx in @(-35, -15, 15, 35)) {
    foreach ($dy in @(-6, 6)) {
      try {
        $c = Get-GamePixel -Game $Game -ReferenceX ($Point[0] + $dx) -ReferenceY ($Point[1] + $dy)
      } catch { continue }
      $chMax = [Math]::Max([int]$c.R, [Math]::Max([int]$c.G, [int]$c.B))
      $chMin = [Math]::Min([int]$c.R, [Math]::Min([int]$c.G, [int]$c.B))
      if ($chMax -gt 150 -and ($chMax - $chMin) -gt 60) { $hits++ }
    }
  }
  return ($hits -ge 2)
}

function Confirm-TabSelected {
  param(
    [System.Diagnostics.Process]$Game,
    [int[]]$Point,
    [string]$Label
  )

  # 탭 클릭 사후 검증: 두 탭의 입장 버튼 영역이 겹쳐 있어 화면 대기만으로는 탭 클릭
  # 실패를 못 잡는 경우가 있으므로(함께하기를 눌렀는데 혼자하기 화면 그대로인 경우 등),
  # 선택 배경색으로 한 번 더 확인합니다. 실패 시 1회 재클릭, 그래도 안 되면 경고만 남기고
  # 진행합니다 (같은 탭 재클릭은 부작용이 없어 재시도가 안전).
  for ($tryNo = 1; $tryNo -le 2; $tryNo++) {
    if (Test-TabSelectedAt -Game $Game -Point $Point) {
      if ($tryNo -gt 1) { Write-RunLog "$($script:contentTag) $Label 탭 재클릭으로 선택 확인" }
      return $true
    }
    if ($tryNo -lt 2) {
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $Point[0] -ReferenceY $Point[1]
      Start-Sleep -Milliseconds 800
    }
  }
  Write-RunLog "[경고] $Label 탭 선택 상태를 확인하지 못했습니다 - 현재 상태로 진행합니다"
  return $false
}

function Set-DgToggleCard {
  param(
    [System.Diagnostics.Process]$Game,
    [int[]]$Region,
    [int[]]$ClickPoint,
    [bool]$WantSelected,
    [string]$Label,
    [int[]]$AltRegion = $null
  )

  # 은동전(소탕)/더블 루팅 카드의 상태를 설정값에 맞춥니다. 버튼 글자가
  # '선택됨' = 사용 중 / '도전' = 미사용이며, 클릭할 때마다 서로 전환됩니다.
  # ('선택됨'이 OCR에서 'A-I태됨'처럼 깨져도 '됨'은 남아서 판별 가능 - 실측 확인)
  # 버튼은 상태에 따라 위치·폭이 달라('선택됨'=넓고 우측 / '도전'=좁고 좌측) 한 영역으로
  # 두 상태를 다 읽지 못합니다. 주 영역에서 판별이 안 되면 보조 영역(AltRegion)을 읽습니다.
  $lastText = ''
  $clicked = $false
  for ($setTry = 1; $setTry -le 6; $setTry++) {
    $lastText = (Get-GameRegionOcrText -Game $Game -ReferenceX $Region[0] -ReferenceY $Region[1] `
      -RegionWidth $Region[2] -RegionHeight $Region[3] -Scale 5 -Engine $ocrKoreanEngine) -replace '\s', ''
    # '선태되' = '선택됨' 깨짐 실측 (2026-07-19 00:21 - '됨'도 '선택'도 안 남아 판별 불가였음)
    $isSelected = ($lastText.Contains('됨') -or $lastText.Contains('선택') -or $lastText.Contains('선태'))
    $isChallenge = $lastText.Contains('도전')
    if (-not ($isSelected -or $isChallenge) -and $AltRegion) {
      $altText = (Get-GameRegionOcrText -Game $Game -ReferenceX $AltRegion[0] -ReferenceY $AltRegion[1] `
        -RegionWidth $AltRegion[2] -RegionHeight $AltRegion[3] -Scale 5 -Engine $ocrKoreanEngine) -replace '\s', ''
      if ($altText) { $lastText = $altText }
      # '선태되' = '선택됨' 깨짐 실측 (2026-07-19 00:21 - '됨'도 '선택'도 안 남아 판별 불가였음)
    $isSelected = ($lastText.Contains('됨') -or $lastText.Contains('선택') -or $lastText.Contains('선태'))
      $isChallenge = $lastText.Contains('도전')
    }
    if (-not ($isSelected -or $isChallenge)) {
      # 은동전이 부족하면 게임이 카드를 자동 해제하고 버튼을 회색 비활성('도전')으로
      # 바꾸는데, 회색 글자는 대비가 낮아 OCR이 못 읽습니다 (실측: 두 영역 모두 빈값).
      # 버튼 배경색으로 보완 판별: 활성 버튼은 보라색(B가 높음), 비활성은 무채색 회색이라
      # 샘플 픽셀이 전부 회색이면 '미사용(도전)' 상태로 간주합니다.
      $graySamples = 0; $totalSamples = 0
      foreach ($dxOffset in @(-25, 0, 25)) {
        try {
          $pxColor = Get-GamePixel -Game $Game -ReferenceX ($ClickPoint[0] + $dxOffset) -ReferenceY $ClickPoint[1]
        } catch { continue }
        $totalSamples++
        $chMax = [Math]::Max([int]$pxColor.R, [Math]::Max([int]$pxColor.G, [int]$pxColor.B))
        $chMin = [Math]::Min([int]$pxColor.R, [Math]::Min([int]$pxColor.G, [int]$pxColor.B))
        # 표본이 검정에 가까우면(RDP 최소화 중 빈 프레임) 회색으로 치지 않습니다.
        # 빈 프레임을 '도전(미사용) 확정'으로 오판해 카드를 블라인드 클릭하는 것을 방지
        # (실측 회색 비활성 버튼은 밝기가 충분해 이 문턱에 걸리지 않음)
        $chSum = [int]$pxColor.R + [int]$pxColor.G + [int]$pxColor.B
        if ($chSum -ge 45 -and ($chMax - $chMin) -lt 40 -and $pxColor.B -lt 130) { $graySamples++ }
      }
      if ($totalSamples -gt 0 -and $graySamples -eq $totalSamples) {
        $isChallenge = $true
        $lastText = '(회색 비활성 - 은동전 부족으로 게임이 해제함)'
      }
    }
    if (-not ($isSelected -or $isChallenge)) {
      # 글자를 못 읽은 상태. 해제된 카드는 버튼 글자가 사라지거나 흐려져 OCR이 실패하는데,
      # 이미 원하는 방향으로 한 번 클릭했다면 그 클릭으로 설정은 반영된 것이므로 성공 처리합니다
      # (재확인만 불가). 아직 클릭 전이면 화면 전환 중일 수 있어 잠시 기다렸다 다시 확인합니다.
      if ($clicked) {
        Write-RunLog "$($script:contentTag) $Label = $(if ($WantSelected) { '사용' } else { '미사용' })으로 설정 (재확인 생략)"
        return $true
      }
      Start-Sleep -Milliseconds 800
      continue
    }
    if ($isSelected -eq $WantSelected) {
      Write-RunLog "$($script:contentTag) $Label = $(if ($WantSelected) { '사용(선택됨)' } else { '미사용(도전)' }) 확인"
      return $true
    }
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ClickPoint[0] -ReferenceY $ClickPoint[1]
    Write-RunLog "$($script:contentTag) $Label 버튼 클릭 → $(if ($WantSelected) { '사용' } else { '미사용' })으로 변경"
    $clicked = $true
    Start-Sleep -Milliseconds 1100
  }
  # 여기 도달: 클릭했는데도 계속 반대 상태로 읽히거나(설정이 안 먹힘), 클릭 전부터 계속 판별 불가
  Write-RunLog "[경고] $Label 상태를 설정값에 맞추지 못했습니다 (버튼 OCR: '$lastText') - 현재 상태로 진행합니다"
  return $false
}

function Invoke-NormalDungeonCycle {
  param([System.Diagnostics.Process]$Game)

  # '던전' 자동화 - 현재 구현 범위:
  #   선택 화면(난이도/스테이지 선택·검증) → 진입 옵션(은동전 소탕/더블 루팅/매칭) → 입장
  #   → 던전 내부(어비스와 동일: 자동출발 → 클리어 대기 → 터치 → 나가기)까지.
  # 클리어 후 결과 화면에서 '다시 하기'로 진입 옵션 화면까지 복귀하고 정상 종료(코드 0)하면,
  # GUI가 다음 회차 워커를 띄워 옵션 화면부터 이어가는 방식으로 반복됩니다.
  $script:contentTag = '[던전]'
  Write-RunLog "[던전] 자동화 시작: 난이도 '$ndDifficulty', 스테이지 '$ndStage', 은동전 $(if ($ndUseCoin) { '사용' } else { '미사용' }), 더블 루팅 $(if ($ndDoubleLoot) { '켬' } else { '끔' }), 매칭 '$ndMatching'"

  if (-not $ndStagePoints.ContainsKey($ndStage)) {
    throw "알 수 없는 스테이지입니다: '$ndStage' (지원: $($ndStagePoints.Keys -join ', '))"
  }
  $stageParts = $ndStage -split '-'
  $stageFloor = $stageParts[0]
  $stageArea = $stageParts[1]

  # 0. 현재 화면 판별: 좌상단 제목이 'N구역'을 포함하면 이미 진입 옵션 화면입니다.
  #    선택 화면 제목에는 던전 이름과 '던전'이 들어갑니다. OCR이 이름 일부를 깨뜨리는
  #    경우까지 고려해 '던전'/'오드' 조각을 함께 봐서 느슨하게 확인합니다.
  #    선택/옵션 화면 둘 다 아니면, 던전 안에서 재시작한 경우인지 확인합니다
  #    (게임플레이 HUD + 퀘스트 추적기의 'N구역 클리어' 목표로 판별).
  $readDgTitle = {
    (Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
      -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
  }
  $titleText = & $readDgTitle
  $onOptionsScreen = $titleText.Contains('구역')

  # 0-1. 옵션 화면이라면 제목의 스테이지(N층 M구역)가 설정과 같은지 확인합니다.
  #      '다시 하기' 복귀 회차라면 항상 일치하지만, 사용자가 다른 스테이지의 옵션 화면을
  #      열어 둔 채 시작하면 검증 없이 그 스테이지로 입장하는 사고가 됩니다
  #      (2026-07-18 실측: 설정 1-3인데 2-3 옵션 화면에서 시작 → 그대로 2-3 입장).
  #      OCR 숫자 오독으로 멀쩡한 복귀 회차를 되돌리는 일이 없도록 재확인까지 해서,
  #      '다른 스테이지'가 명확히 읽힌 경우에만 선택 화면으로 되돌아갑니다.
  if ($onOptionsScreen -and ($titleText -notmatch "${stageFloor}\D{1,2}${stageArea}구역")) {
    Start-Sleep -Milliseconds 700
    $titleText = & $readDgTitle
    $titleStageWrong = $false
    # 구분자('층')는 통째로 소실될 수 있어 {0,2}로 허용합니다 ('2층3구역'→'23구역').
    # 잘못 판정해도 선택 화면으로 돌아가 다시 고르므로 결과는 항상 설정 스테이지가 됩니다.
    if ($titleText -match "(\d)\D{0,2}(\d)구역") {
      $titleStageWrong = -not (($Matches[1] -eq $stageFloor) -and ($Matches[2] -eq $stageArea))
    }
    if ($titleStageWrong) {
      Write-RunLog "[던전] 시작: 진입 옵션 화면이 설정과 다른 스테이지입니다 (제목: '$titleText', 설정: ${ndStage}) - 선택 화면으로 되돌아갑니다"
      # 상태 기반 뒤로 가기: 매번 화면을 먼저 판독하고, 옵션 화면('구역')이 그대로
      # 보일 때만 좌상단 '<'를 클릭합니다. 전환 중이라 판독이 불명확하면 입력 없이
      # 기다렸다가 재확인합니다 (복귀가 이미 성공했는데 판독이 한 번 흔들렸다고
      # 여분의 입력을 쏘지 않기 위함 - 무조건 재클릭 금지 원칙).
      # 주의: ESC/우상단 X는 한 단계 뒤로가 아니라 던전 UI 전체를 닫고 필드로
      # 나가버립니다 (2026-07-18 18:44 실측 - 좌상단 '<'만 선택 화면으로 돌아감).
      $backOk = $false
      $backInputs = 0
      for ($backTry = 1; $backTry -le 10; $backTry++) {
        $titleText = & $readDgTitle
        if (-not $titleText.Contains('구역')) {
          if ($titleText.Contains('던전') -or $titleText.Contains('오드')) { $backOk = $true; break }
          # 던전 UI 밖(필드 HUD)으로 나가버렸으면 더 조작하지 않고 아래 오류로 안내합니다
          if (Test-HomeEndEscHud -Game $Game) { break }
          Start-Sleep -Milliseconds 1500   # 전환 중/판독 불명확 - 입력 없이 재확인
          continue
        }
        if ($backInputs -ge 4) { break }
        $backInputs++
        Focus-Game -Game $Game
        Click-GamePoint -Game $Game -ReferenceX $ptDgBackArrow[0] -ReferenceY $ptDgBackArrow[1]
        Write-RunLog "[던전] 선택 화면으로 뒤로 가기: 좌상단 < 클릭 (${backInputs}/4)"
        Start-Sleep -Milliseconds 1500
      }
      if (-not $backOk) {
        throw "설정(${ndStage})과 다른 스테이지의 진입 옵션 화면에서 선택 화면으로 돌아가지 못했습니다 (제목 영역 OCR: '$titleText'). 게임에서 원하는 던전의 구역 선택 화면을 열어 두고 다시 시작해 주세요."
      }
      Write-RunLog '[던전] 선택 화면 복귀 확인 - 난이도/스테이지 선택부터 진행합니다'
      $onOptionsScreen = $false
    } elseif ($titleText.Length -gt 0) {
      # 재확인에서 설정과 일치했거나 숫자를 명확히 읽지 못한 경우: 새 판독 기준으로 진행
      $onOptionsScreen = $titleText.Contains('구역')
    }
    # 재판독이 빈 문자열(일시 캡처 실패)이면 첫 판독(옵션 화면) 판정을 그대로 둡니다
  }
  $insideAlready = $false
  $onResultScreen = $false
  if (-not $onOptionsScreen -and -not ($titleText.Contains('오드') -or $titleText.Contains('던전'))) {
    # 던전 안에서만 퀘스트 추적기에 'N층 M구역 클리어' 목표가 표시됩니다.
    # ('던전' 키워드는 필드의 주간 퀘스트("심층 던전 클리어" 등)와 겹쳐 오인하므로 '구역'만 사용)
    $questText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgQuestTracker[0] -ReferenceY $rgQuestTracker[1] `
      -RegionWidth $rgQuestTracker[2] -RegionHeight $rgQuestTracker[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
    if ((Test-HomeEndEscHud -Game $Game) -and $questText.Contains('구역')) {
      $insideAlready = $true
      Write-RunLog '[던전] 시작: 던전 안 상태 감지 - 클리어 대기부터 재개'
    } elseif (Find-DgRetryButtonPoint -Game $Game) {
      $onResultScreen = $true
      Write-RunLog '[던전] 시작: 결과 화면 감지 - 재입장부터 진행'
    } elseif (Test-DungeonClearPrompt -Game $Game) {
      # 클리어 화면(화면을 터치)에 멈춘 채 재시작한 경우: 터치로 넘긴 뒤 결과 처리부터 이어갑니다
      Write-RunLog '[던전] 시작: 클리어 화면 감지 - 화면 터치부터 진행'
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
      Start-Sleep -Seconds 2
      $onResultScreen = $true
    } else {
      throw "던전 화면이 아닙니다. 게임에서 원하는 던전의 구역 선택 화면을 열어 두고 시작해 주세요. (제목 영역 OCR: '$titleText')"
    }
  }

  if (-not $onResultScreen) {

  if (-not $insideAlready) {

  if (-not $onOptionsScreen) {
  Write-RunLog '[던전] 1. 던전 선택 화면 확인'

  # 2. 난이도 클릭 (일반/어려움 - 이미 선택돼 있어도 다시 눌러 확정, 부작용 없음)
  $difficultyKey = $ndDifficulty -replace '\s', ''
  $difficultyPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgDgDifficulty[0] -ReferenceY $rgDgDifficulty[1] `
    -RegionWidth $rgDgDifficulty[2] -RegionHeight $rgDgDifficulty[3] -Scale 4 -SearchText $difficultyKey -ExactText $difficultyKey
  if ($difficultyPoint) {
    Focus-Game -Game $Game
    Click-ScreenPoint -X $difficultyPoint.X -Y $difficultyPoint.Y
    Write-RunLog "[던전] 2. 난이도 '$ndDifficulty' 클릭"
    Start-Sleep -Milliseconds 900
    # 사후 검증: 클릭이 빗나가 다른 난이도로 바뀌지 않았는지 선택 강조로 확인 (첫 좌표 재사용)
    Confirm-DifficultySelected -Game $Game -ClickPoint $difficultyPoint -Label $ndDifficulty | Out-Null
  } else {
    Write-RunLog "[경고] 난이도 '$ndDifficulty' 글자를 찾지 못했습니다 - 현재 선택된 난이도로 진행합니다"
  }

  # 3. 스테이지 노드 클릭 후 '진입' 버튼 문구(N층 M구역)로 선택을 검증합니다.
  #    ('층'이 OCR에서 '츰' 등으로 읽히는 경우가 있어 층 글자는 느슨하게 확인)
  $stageSelected = $false
  $enterText = ''
  for ($stageTry = 1; $stageTry -le 4; $stageTry++) {
    # 지도가 스크롤로 흐를 수 있어 매 시도마다 라벨을 읽어 클릭 지점을 다시 계산합니다
    $stagePoint = Get-NdStageClickPoint -Game $Game -Stage $ndStage
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $stagePoint[0] -ReferenceY $stagePoint[1]
    Start-Sleep -Milliseconds 900
    $enterText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgEnterBtn[0] -ReferenceY $rgDgEnterBtn[1] `
      -RegionWidth $rgDgEnterBtn[2] -RegionHeight $rgDgEnterBtn[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
    # 주의: "$stageArea구역"처럼 한글을 변수명에 붙이면 PS가 'stageArea구역'이라는
    # 변수로 해석해 빈 문자열이 됩니다 (스테이지 검증이 무력화됐던 원인) - ${} 필수
    if ($enterText -match "${stageFloor}\D{1,2}${stageArea}구역") {
      $stageSelected = $true
      break
    }
  }
  if (-not $stageSelected) {
    throw "스테이지 $ndStage 선택이 확인되지 않습니다 (진입 버튼 문구: '$enterText'). 스테이지가 잠겨 있는지 확인해 주세요."
  }
  Write-RunLog "[던전] 3. 스테이지 $ndStage 선택 확인 (진입 버튼: ${stageFloor}층 ${stageArea}구역 진입)"

  # 4. 진입 클릭 → 진입 옵션 화면(제목에 'N구역' 표시)이 뜰 때까지 확인하며 재클릭
  Write-RunLog "[던전] 4. ${stageFloor}층 ${stageArea}구역 진입 클릭"
  Invoke-ClickUntil -Game $Game -Point $ptDgStageEnter -Description '던전 진입 옵션 화면' -TimeoutSeconds 20 -Condition {
    ((Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
        -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', '').Contains('구역')
  }
  } else {
    Write-RunLog '[던전] 시작: 진입 옵션 화면 감지 - 옵션 설정부터 진행'
    # 옵션 화면 상단에도 난이도 알약(일반/어려움)이 있어 여기서 바꿀 수 있습니다 (2026-07-18 실측).
    # 다른 난이도로 열어 둔 채 시작해도 설정대로 가도록 설정 난이도를 한 번 눌러 확정합니다
    # (이미 선택돼 있어도 다시 눌러 부작용 없음 - 선택 화면 2단계와 같은 방식.
    #  이 화면의 선택 강조는 보라색 계열이라 금색 기준의 강조 사후 확인은 생략).
    $optDifficultyKey = $ndDifficulty -replace '\s', ''
    $optDifficultyPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgDgOptDifficulty[0] -ReferenceY $rgDgOptDifficulty[1] `
      -RegionWidth $rgDgOptDifficulty[2] -RegionHeight $rgDgOptDifficulty[3] -Scale 4 -SearchText $optDifficultyKey -ExactText $optDifficultyKey
    if ($optDifficultyPoint) {
      Focus-Game -Game $Game
      Click-ScreenPoint -X $optDifficultyPoint.X -Y $optDifficultyPoint.Y
      Write-RunLog "[던전] 난이도 '$ndDifficulty' 확정 클릭 (옵션 화면)"
      Start-Sleep -Milliseconds 900
    } else {
      Write-RunLog "[경고] 옵션 화면에서 난이도 '$ndDifficulty' 글자를 찾지 못했습니다 - 현재 선택된 난이도로 진행합니다"
    }
  }
  Write-RunLog '[던전] 5. 진입 옵션 화면 확인'

  # 5. 은동전(소탕)/더블 루팅을 설정값에 맞춥니다 (선택됨 = 사용 / 도전 = 미사용).
  #    비용: 소탕 10개, 더블 루팅 +10개(합 20개). '소진 시 미사용으로 계속'이 켜져 있으면
  #    잔량을 먼저 읽어 부족한 만큼 단계적으로 낮춥니다 (20개 미만 → 더블 루팅만 끔 /
  #    10개 미만 → 소탕도 해제하고 미사용으로).
  $effectiveCoin = $ndUseCoin
  $effectiveLoot = $ndDoubleLoot
  if ($ndUseCoin -and ($ndCoinFallback -or ($ndDoubleLoot -and $ndLootFallback))) {
    $coinBalance = Get-DgCoinBalance -Game $Game
    if ($null -ne $coinBalance) {
      if ($coinBalance -lt 10) {
        # 소탕 자체가 불가능한 잔량: '소진 시 미사용으로 계속'이 켜져 있을 때만 낮춥니다
        if ($ndCoinFallback) {
          $effectiveCoin = $false
          $effectiveLoot = $false
          Write-RunLog "[던전] 은동전 잔량 ${coinBalance}개 (소탕에 10개 필요) - 소탕을 해제하고 미사용으로 진행합니다"
        }
      } elseif ($ndDoubleLoot -and $coinBalance -lt 20) {
        # 더블 루팅(합 20개)만 불가능한 잔량: 옵션에 따라 소탕만 계속 / 미사용으로 전환
        if ($ndLootFallback) {
          $effectiveLoot = $false
          Write-RunLog "[던전] 은동전 잔량 ${coinBalance}개 (더블 루팅 포함 20개 필요) - 더블 루팅만 끄고 소탕(10개)으로 계속합니다"
        } elseif ($ndCoinFallback) {
          $effectiveCoin = $false
          $effectiveLoot = $false
          Write-RunLog "[던전] 은동전 잔량 ${coinBalance}개 - 더블 루팅 불가('소탕만 계속' 옵션 꺼짐)라 소탕까지 해제하고 미사용으로 진행합니다"
        }
      }
    }
  }
  Set-DgToggleCard -Game $Game -Region $rgDgCoinButton -AltRegion $rgDgCoinButtonAlt -ClickPoint $ptDgCoinButton -WantSelected $effectiveCoin -Label '은동전(소탕)' | Out-Null
  # 더블 루팅은 소탕(은동전) 전제 기능이라, 소탕을 해제하면 카드 자체가 화면에서 사라집니다.
  # 소탕을 사용할 때만 더블 루팅 상태를 맞추고, 미사용이면 확인을 생략합니다.
  if ($effectiveCoin) {
    Set-DgToggleCard -Game $Game -Region $rgDgLootButton -AltRegion $rgDgLootButtonAlt -ClickPoint $ptDgLootButton -WantSelected $effectiveLoot -Label '더블 루팅' | Out-Null

    # 5-1. '입장하기' 버튼의 공물(은동전) 소모량으로 더블 루팅 설정을 교차 검증합니다.
    #      소탕만 = 10, 더블 루팅까지 = 20. 카드 버튼 글자('선택됨'/'도전')보다 크고
    #      또렷해 더 확실합니다. 예상과 다르고 값이 유효(10/20)하면 더블 루팅 버튼을
    #      한 번 눌러 정정하고, 그래도 안 맞거나 값이 이상하면 경고만 남기고 진행합니다.
    Start-Sleep -Milliseconds 500
    $expectedCost = if ($effectiveLoot) { 20 } else { 10 }
    $actualCost = Get-DgTributeCost -Game $Game
    if ($null -eq $actualCost) {
      Write-RunLog "[던전] 공물 소모량을 읽지 못해 교차 검증을 건너뜁니다 (예상 ${expectedCost}개)"
    } elseif ($actualCost -eq $expectedCost) {
      Write-RunLog "[던전] 공물 소모량 ${actualCost}개 확인 (더블 루팅 $(if ($effectiveLoot) { '켬' } else { '끔' })과 일치)"
    } elseif ($actualCost -eq 10 -or $actualCost -eq 20) {
      Write-RunLog "[경고] 공물 소모량 불일치 (예상 ${expectedCost}, 실제 ${actualCost}) - 더블 루팅 버튼을 눌러 정정합니다"
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptDgLootButton[0] -ReferenceY $ptDgLootButton[1]
      Start-Sleep -Milliseconds 1100
      $recheck = Get-DgTributeCost -Game $Game
      if ($null -ne $recheck -and $recheck -eq $expectedCost) {
        Write-RunLog "[던전] 공물 소모량 ${recheck}개로 정정 확인"
      } else {
        Write-RunLog "[경고] 공물 소모량이 여전히 예상(${expectedCost})과 다릅니다 (실제 '$recheck') - 현재 상태로 진행합니다"
      }
    } else {
      Write-RunLog "[경고] 공물 소모량이 예상 밖입니다 (예상 ${expectedCost}, 실제 ${actualCost}) - OCR 오류 가능성이 있어 현재 상태로 진행합니다"
    }
  } else {
    # 5-1(역방향). 미사용(원래 설정이든 '소진 시 미사용으로 계속' 강등이든)인데도 입장
    # 버튼에 소모량(10/20)이 보이면 소탕 카드가 켜진 채 남은 것입니다 (2026-07-19 00:21
    # 실측: 카드 글자가 '선태되'로 깨져 판별 불가 → 해제 클릭을 못 한 채 잔량 6개로
    # 입장하기가 거부돼 45초 헛대기. 버튼 숫자 '10 입장하기'는 멀쩡히 읽혔음).
    # 버튼 숫자가 카드 글자보다 크고 또렷해 이걸로 역방향 검증합니다.
    Start-Sleep -Milliseconds 500
    $offCost = Get-DgTributeCost -Game $Game
    if ($null -ne $offCost -and ($offCost -eq 10 -or $offCost -eq 20)) {
      Write-RunLog "[경고] 은동전 미사용인데 입장 버튼에 소모량 ${offCost}개가 보입니다 - 소탕 카드를 눌러 해제합니다"
      # 상태 기반 해제: 10/20이 '그대로 보일 때만' 클릭(최대 2회)합니다.
      #  - null = 숫자 사라짐(해제 성공). 단 캡처 실패 중의 null은 증거가 아니므로 기다렸다 재확인
      #  - 10/20이 아닌 잡음 숫자 = 순방향 검증과 같은 기준으로 OCR 오류 가능성 - 클릭하지 않고 경고 후 진행
      #    (해제된 카드를 확인 없이 재클릭해 도로 켜는 사고 방지 - 무조건 재클릭 금지 원칙)
      $offCleared = $false
      $offClicks = 0
      for ($offTry = 1; $offTry -le 5; $offTry++) {
        if ($null -eq $offCost) {
          if (-not $script:screenCaptureFailing) { $offCleared = $true; break }
          Start-Sleep -Milliseconds 1500   # 캡처 실패 중 - 입력 없이 재확인
        } elseif ($offCost -eq 10 -or $offCost -eq 20) {
          if ($offClicks -ge 2) { break }
          $offClicks++
          Focus-Game -Game $Game
          Click-GamePoint -Game $Game -ReferenceX $ptDgCoinButton[0] -ReferenceY $ptDgCoinButton[1]
          Start-Sleep -Milliseconds 1100
        } else {
          break
        }
        $offCost = Get-DgTributeCost -Game $Game
      }
      if ($offCleared) {
        Write-RunLog '[던전] 소모량 표시 사라짐 - 은동전 미사용 확인'
      } elseif ($null -ne $offCost -and ($offCost -eq 10 -or $offCost -eq 20)) {
        throw "은동전 미사용 설정인데 소탕을 해제하지 못했습니다 (입장 버튼 소모량: ${offCost}개). 게임에서 소탕 카드를 직접 '도전'으로 바꾼 뒤 다시 시작해 주세요."
      } else {
        Write-RunLog "[경고] 소탕 해제 확인이 불명확합니다 (소모량 판독: '$offCost') - 현재 상태로 진행합니다"
      }
    }
  }

  # 6. 매칭 방식 처리
  if ($ndMatching -eq '우연한 만남') {
    $toggleState = Get-ChanceToggleState -Game $Game -Point $ptDgChanceToggle
    if ($toggleState -eq 'unknown') {
      # 빈 프레임/픽셀 확인 불가: 켜져 있던 토글을 실수로 꺼버리지 않도록 클릭하지 않습니다
      Write-RunLog "[경고] '우연한 만남' 토글 상태를 판별하지 못했습니다(화면 확인 불가) - 클릭 없이 현재 상태로 진행합니다"
    } elseif ($toggleState -ne 'on') {
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptDgChanceToggle[0] -ReferenceY $ptDgChanceToggle[1]
      Start-Sleep -Milliseconds 900
      if ((Get-ChanceToggleState -Game $Game -Point $ptDgChanceToggle) -eq 'on') {
        Write-RunLog "[던전] 6. '우연한 만남' 토글 켬"
      } else {
        Write-RunLog "[경고] '우연한 만남' 토글이 켜진 것을 확인하지 못했습니다 - 현재 상태로 진행합니다"
      }
    } else {
      Write-RunLog "[던전] 6. '우연한 만남' 토글 켜짐 확인"
    }
    # 7. 입장하기 클릭 → 옵션 화면을 실제로 벗어나는지 확인하며 재시도합니다.
    #    은동전이 부족하면 입장하기가 비활성이라 화면이 그대로 남는데, 이때
    #    '소진 시 미사용으로 계속' 설정이 켜져 있으면 소탕 선택을 해제하고 이어갑니다.
    Write-RunLog '[던전] 7. 입장하기 클릭'
    $entered = $false
    $coinFallbackDone = $false
    $lootFallbackDone = $false
    for ($enterTry = 1; $enterTry -le 5; $enterTry++) {
      # 캡처 실패 중에는 입장 여부를 확인할 수 없는 채 클릭/시도 횟수만 소모되므로,
      # 제목 OCR을 복구 탐침 삼아 캡처가 돌아올 때까지 기다렸다가 진행합니다.
      while ($script:screenCaptureFailing) {
        Test-SafeStopDuringCaptureFail
        Start-Sleep -Seconds 2
        Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
          -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine | Out-Null
      }
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptDgEnterFinal[0] -ReferenceY $ptDgEnterFinal[1]
      Start-Sleep -Milliseconds 1200

      # 7-1. '던전에 입장하시겠습니까?' 확인 팝업(도전 미수락 시)이 뜨면 처리합니다.
      Resolve-DgEnterConfirmPopup -Game $Game | Out-Null

      # 옵션 화면(제목 'N구역')을 벗어났으면 입장(로딩)이 시작된 것입니다.
      # 로딩이 늦게 시작할 수 있어 2초 뒤 한 번 더 확인합니다.
      $titleNow = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
        -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
      if ($titleNow.Contains('구역')) {
        Start-Sleep -Seconds 2
        $titleNow = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
          -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
      }
      # 캡처 실패 중의 빈 OCR('')을 '옵션 화면을 벗어남'으로 오판하지 않도록 함께 확인합니다.
      if (-not $titleNow.Contains('구역') -and -not $script:screenCaptureFailing) {
        $entered = $true
        break
      }

      # 여전히 옵션 화면: 클릭이 빗나갔거나 은동전이 부족한 상태입니다 (잔량 OCR을 놓친 경우 대비).
      # 두 번째 실패부터 은동전 부족으로 판단하고, 옵션에 따라 단계적으로 낮춥니다:
      # '소탕만 계속'이 켜져 있으면 더블 루팅(합 20개)만 먼저 끄고, 그래도 안 되면
      # '미사용으로 계속'이 켜져 있을 때 소탕(10개)까지 해제합니다.
      # 캡처 순단이 원인일 수 있는 실패에는 폴백(카드 해제)을 발동하지 않습니다
      if ($enterTry -ge 2 -and $ndUseCoin -and -not $script:screenCaptureFailing) {
        if ($effectiveLoot -and $ndLootFallback -and -not $lootFallbackDone) {
          Write-RunLog '[던전] 입장 안 됨 - 더블 루팅(합 20개 필요)부터 끄고 재시도'
          Set-DgToggleCard -Game $Game -Region $rgDgLootButton -AltRegion $rgDgLootButtonAlt -ClickPoint $ptDgLootButton -WantSelected $false -Label '더블 루팅' | Out-Null
          $effectiveLoot = $false
          $lootFallbackDone = $true
        } elseif ($ndCoinFallback -and -not $coinFallbackDone) {
          Write-RunLog '[던전] 입장 안 됨(은동전 부족 추정) - 소탕 해제 후 미사용으로 계속'
          if ($effectiveLoot) {
            Set-DgToggleCard -Game $Game -Region $rgDgLootButton -AltRegion $rgDgLootButtonAlt -ClickPoint $ptDgLootButton -WantSelected $false -Label '더블 루팅' | Out-Null
            $effectiveLoot = $false
          }
          Set-DgToggleCard -Game $Game -Region $rgDgCoinButton -AltRegion $rgDgCoinButtonAlt -ClickPoint $ptDgCoinButton -WantSelected $false -Label '은동전(소탕)' | Out-Null
          $coinFallbackDone = $true
        }
      }
    }
    if (-not $entered) {
      # 은동전 소진이 원인이면 (사용자가 '계속' 옵션을 끈 상태) 오류가 아니라
      # '조건에 따른 정상 정지'로 마칩니다 (종료 코드 4 - 컨트롤 패널이 구분해 표시).
      $finalBalance = Get-DgCoinBalance -Game $Game
      $neededNow = $(if ($effectiveLoot) { 20 } elseif ($effectiveCoin) { 10 } else { 0 })
      if ($ndUseCoin -and $null -ne $finalBalance -and $neededNow -gt 0 -and $finalBalance -lt $neededNow) {
        Write-RunLog "[완료] 은동전 소진(잔량 ${finalBalance}개, 필요 ${neededNow}개) - '소진 시 계속' 옵션이 꺼져 있어 설정대로 자동화를 마칩니다"
        exit 4
      }
      throw "입장하기가 진행되지 않습니다. 은동전 잔량을 확인해 주세요 (부족하면 '소진 시 미사용으로 계속' 옵션을 켜면 자동으로 이어갑니다)."
    }
  } else {
    # 파티찾기: '우연한 만남' 토글이 켜져 있으면 파티 찾기 버튼이 없고 그 자리가 넓은
    # 입장하기 버튼이라, 잘못 누르면 우연한 만남(혼자)으로 입장돼 버립니다.
    # 어비스와 동일하게 토글을 먼저 끄고 꺼짐을 확인한 뒤 파티 찾기를 클릭합니다.
    $toggleState = Get-ChanceToggleState -Game $Game -Point $ptDgChanceToggle
    if ($toggleState -eq 'on') {
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptDgChanceToggle[0] -ReferenceY $ptDgChanceToggle[1]
      Start-Sleep -Milliseconds 900
      if ((Get-ChanceToggleState -Game $Game -Point $ptDgChanceToggle) -eq 'on') {
        throw "'우연한 만남' 토글을 끄지 못해 파티찾기를 진행할 수 없습니다 (토글이 켜진 상태에서는 파티 찾기 버튼이 없음)"
      }
      Write-RunLog "[던전] '우연한 만남' 토글 끔 (파티찾기 준비)"
    } elseif ($toggleState -eq 'unknown') {
      Write-RunLog "[경고] '우연한 만남' 토글 상태를 판별하지 못했습니다(화면 확인 불가) - 꺼짐으로 보고 진행합니다"
    }
    # 클릭하면 자동으로 파티 매칭이 진행되고, 파티가 구성되면 게임이 알아서
    # 던전에 입장합니다. 여기서는 클릭 후 아래의 입장 감지에서 매칭 완료를 기다립니다.
    Write-RunLog "[던전] 6. '파티 찾기' 클릭 - 파티 매칭을 기다립니다"
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ptDgPartyFind[0] -ReferenceY $ptDgPartyFind[1]
    Start-Sleep -Milliseconds 1200
    # 입장 확인 팝업이 뜨는 경우 동일하게 처리합니다
    Resolve-DgEnterConfirmPopup -Game $Game | Out-Null
  }

  # 8. 던전 로딩/입장 완료 대기.
  #    - 우연한 만남: 바로 로딩되므로 HUD 표시로 판단 (어비스와 동일)
  #    - 파티찾기: 매칭 중에는 캐릭터가 필드에 나와 대기하는데 필드에도 HUD가 보이므로,
  #      HUD 대신 퀘스트 추적기의 'N구역 클리어' 목표(던전 안에서만 표시)로 입장을 판단합니다.
  Write-RunLog '[던전] 8. 던전 로딩 중...'
  Start-Sleep -Seconds 1
  if ($ndMatching -eq '우연한 만남') {
    Wait-ForScreen -Game $Game -TimeoutSeconds $timeoutEntry -Description '던전 입장 완료 화면' -Condition {
      Test-DungeonEntered -Game $Game
    }
  } else {
    Wait-ForScreen -Game $Game -TimeoutSeconds $timeoutPartyMatch -Description '파티 매칭 완료 후 던전 입장' -Condition {
      ((Get-GameRegionOcrText -Game $Game -ReferenceX $rgQuestTracker[0] -ReferenceY $rgQuestTracker[1] `
          -RegionWidth $rgQuestTracker[2] -RegionHeight $rgQuestTracker[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', '').Contains('구역')
    }
  }
  Write-RunLog '[던전] 9. 던전 입장 완료 감지'

  # 입장 후 키 입력 (자동출발/음식 - 어비스와 동일한 설정을 그대로 사용)
  Invoke-AfterEntryKeys -Game $Game -LogPrefix '[던전]'

  }  # end if (-not $insideAlready)

  # 10. 클리어 대기 - 어비스와 동일한 감지/안전장치(자동사냥 꺼짐 감시, 자동 부활,
  #     컷신 장면 넘기기, 구매 팝업 닫기)를 전부 그대로 사용합니다.
  Write-RunLog '[던전] 10. 던전 클리어 화면 감지 대기 시작'
  $clearOutcome = Wait-ForDungeonClearScreen -Game $Game -TimeoutSeconds $timeoutClear -DungeonMode `
    -FindResultButton { Find-DgRetryButtonPoint -Game $Game }
  if ($clearOutcome -eq 'clear') {
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
    Write-RunLog '[던전] 11. 던전 클리어 - 화면 터치'
  } else {
    Write-RunLog "[던전] 11. 클리어 화면을 이미 지나친 상태($clearOutcome) - 결과 화면 처리로 진행"
  }

  }  # end if (-not $onResultScreen)

  # 12. 클리어 터치 후에는 엔딩 컷신이 나옵니다. '장면 넘기기'를 눌러 넘기고,
  #     결과 화면(전리품 + 나가기/다시 하기)이 나타날 때까지 기다립니다.
  if (-not $onResultScreen) {
    Write-RunLog '[던전] 12. 결과 화면 대기 (엔딩 컷신은 자동으로 넘김)'
  }
  $dgRetryPoint = Wait-ForResultScreen -Game $Game -MissingMessage '던전 결과 화면(다시 하기 버튼)을 찾지 못했습니다.' `
    -FindRetryButton { Find-DgRetryButtonPoint -Game $Game }
  Write-RunLog '[던전] 13. 결과 화면 확인 (나가기 / 다시 하기)'

  # 14. 안전 중지가 예약돼 있으면 나가기로 마치고, 아니면 다시 하기로 곧장 재입장합니다.
  Invoke-SafeStopExitIfRequested -Game $Game

  # 14-1. 은동전이 소탕(10개)에도 모자라고 '소진 시 미사용으로 계속'이 꺼져 있으면,
  #       다시 하기로 재입장해도 설정상 진행할 수 없으므로 나가기를 누르고
  #       '조건에 따른 정상 정지'(코드 4)로 마칩니다. 결과 화면 우상단 재화 표시줄에서
  #       잔량을 읽습니다 ('은동전이 부족해요' 말풍선이 뜨는 상황 - 실측 검증).
  if ($ndUseCoin -and -not $ndCoinFallback) {
    $resultBalance = Get-DgCoinBalance -Game $Game
    if ($null -ne $resultBalance -and $resultBalance -lt 10) {
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptDgResultExit[0] -ReferenceY $ptDgResultExit[1]
      Write-RunLog "[완료] 은동전 소진(잔량 ${resultBalance}개, 소탕에 10개 필요) - '소진 시 미사용으로 계속'이 꺼져 있어 나가기를 누르고 설정대로 자동화를 마칩니다"
      Start-Sleep -Seconds 2
      exit 4
    }
  }
  # '다시 하기'는 던전에 바로 들어가지 않고 진입 옵션 화면으로 돌아갑니다(도전을 다시 고를
  # 기회를 줌). 옵션 화면이 뜨면 이번 회차를 마치고, 다음 회차 워커가 '옵션 화면'을
  # 인식해 은동전/더블 루팅 설정부터 이어갑니다.
  # 주의 (2026-07-18 17:04 실측 사고): 던전 밖에서 진행할 퀘스트가 있으면 다시 하기 뒤에
  # '던전 탐험을 계속하시겠습니까?' 팝업(계속하기=ESC / 나가기=Space)이 끼어듭니다.
  # 무조건 재클릭하면 그 자리가 팝업의 '나가기' 버튼이라 던전 밖으로 나가버리므로,
  # '계속하'가 보이면 계속하기를 누르고, 재클릭은 결과 화면(다시 하기 버튼)이
  # 그대로 보일 때만 합니다 (사냥터 '새 임무 선택'과 동일한 규칙).
  # 3버튼 배치에서 옛 고정 좌표(757,654)는 '다음 구역으로' 자리라, 탐색으로 찾은
  # '다시 하기' 글자 지점을 클릭합니다 (다른 스테이지로 넘어가는 오클릭 방지 - 실측).
  Focus-Game -Game $Game
  if ($dgRetryPoint) {
    Click-ScreenPoint -X $dgRetryPoint.X -Y $dgRetryPoint.Y
  } else {
    Click-GamePoint -Game $Game -ReferenceX $ptDgRetry[0] -ReferenceY $ptDgRetry[1]
  }
  Write-RunLog "[던전] 14. '다시 하기' 클릭 - 옵션 화면 복귀 대기"
  $optionsDeadline = (Get-Date).AddSeconds(40)
  $backToOptions = $false
  while ((Get-Date) -lt $optionsDeadline) {
    Start-Sleep -Seconds 2
    if ($script:screenCaptureFailing) {
      Test-SafeStopDuringCaptureFail
      $optionsDeadline = (Get-Date).AddSeconds(40)
      continue
    }
    if (((Get-GameRegionOcrText -Game $Game -ReferenceX $rgDgTitle[0] -ReferenceY $rgDgTitle[1] `
        -RegionWidth $rgDgTitle[2] -RegionHeight $rgDgTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', '').Contains('구역')) {
      $backToOptions = $true
      break
    }
    $centerNow = (Get-GameOcrText -Game $Game) -replace '\s', ''
    if ($centerNow.Contains('계속하')) {
      $contPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgClearExit[0] -ReferenceY $rgClearExit[1] `
        -RegionWidth $rgClearExit[2] -RegionHeight $rgClearExit[3] -SearchText '계속하'
      Focus-Game -Game $Game
      if ($contPoint) {
        Click-ScreenPoint -X $contPoint.X -Y $contPoint.Y
      } else {
        Press-KeyOnce -VirtualKey ([byte]27)   # ESC = 계속하기 (버튼 지점을 못 찾은 경우 예비)
      }
      Write-RunLog "[던전] '던전 탐험을 계속하시겠습니까?' 팝업 - 계속하기 선택"
      Start-Sleep -Seconds 1
      continue
    }
    $retryAgainPoint = Find-DgRetryButtonPoint -Game $Game
    if ($retryAgainPoint) {
      Write-RunLog "[던전] 결과 화면이 남아 있어 '다시 하기'를 다시 클릭합니다"
      Focus-Game -Game $Game
      Click-ScreenPoint -X $retryAgainPoint.X -Y $retryAgainPoint.Y
    }
  }
  if (-not $backToOptions) {
    throw '다시 하기 → 진입 옵션 화면 대기 시간이 초과됐습니다.'
  }
  Write-RunLog '[던전] 14. 다시 하기 → 옵션 화면 복귀 - 회차 완료'
  exit 0
}

function Invoke-HuntingGroundCycle {
  param([System.Diagnostics.Process]$Game)

  # '사냥터' 자동화 - 특정 사냥터에 매이지 않는 범용 방식입니다.
  # 사용자가 원하는 사냥터의 첫 화면(하단에 '파티 찾기 / 입장하기')을 열어 두면
  # 난이도/공물(사냥 임무)을 설정하고 입장 → 사냥 완료 → 결과 → 다시 하기로 반복합니다.
  # 새 사냥터가 게임에 추가되어도 프로그램 수정 없이 그대로 동작합니다.
  $script:contentTag = '[사냥터]'
  Write-RunLog "[사냥터] 자동화 시작: 난이도 '$htDifficulty', 은동전 $(if ($htUseCoin) { '사용' } else { '미사용' })$(if ($htUseCoin -and $htDoubleLoot) { ' + 더블 루팅' }), 매칭 '$htMatching'"

  # 0. 현재 화면 판별: 첫 화면(입장하기 버튼) / 결과 화면(새 임무 선택) / 사냥 진행 중(임무 표시)
  $onEntryScreen = [bool](Find-HtEntryButtonPoint -Game $Game)
  $onResultScreen = $false
  $insideAlready = $false
  if (-not $onEntryScreen) {
    if (Find-HtNewMissionPoint -Game $Game) {
      $onResultScreen = $true
      Write-RunLog '[사냥터] 시작: 결과 화면 감지 - 재입장부터 진행'
    } elseif (Test-DungeonClearPrompt -Game $Game) {
      # 완료 화면(화면을 터치)에 멈춘 채 재시작한 경우: 터치로 넘긴 뒤 결과 처리부터 이어갑니다
      Write-RunLog '[사냥터] 시작: 완료 화면 감지 - 화면 터치부터 진행'
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
      Start-Sleep -Seconds 2
      $onResultScreen = $true
    } else {
      # 사냥 중에는 퀘스트 추적기에 '몬스터 소탕 N회'/'구역 정찰' 같은 사냥 임무가 표시됩니다
      $questText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgQuestTracker[0] -ReferenceY $rgQuestTracker[1] `
        -RegionWidth $rgQuestTracker[2] -RegionHeight $rgQuestTracker[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
      if ((Test-HomeEndEscHud -Game $Game) -and ($questText.Contains('소탕') -or $questText.Contains('정찰'))) {
        $insideAlready = $true
        Write-RunLog '[사냥터] 시작: 사냥 진행 중 감지 - 완료 대기부터 재개'
      } else {
        throw "사냥터 화면이 아닙니다. 원하는 사냥터의 첫 화면(하단에 '파티 찾기 / 입장하기')을 열어 두고 시작해 주세요."
      }
    }
  }

  if (-not $onResultScreen) {

  if (-not $insideAlready) {

  # 1. 난이도 클릭 (화면 상단 중앙의 알약: 일반/어려움, 일부 사냥터는 매우 어려움도 있음).
  #    '매우 어려움'은 두 단어로 읽히므로 앞 2글자('매우')로 찾습니다. 해당 사냥터에
  #    없는 난이도를 선택했으면 글자를 못 찾고 현재 난이도로 그대로 진행합니다.
  $difficultyKey = $htDifficulty -replace '\s', ''
  $difficultySearch = $difficultyKey.Substring(0, [Math]::Min(2, $difficultyKey.Length))
  $difficultyPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgHtDifficulty[0] -ReferenceY $rgHtDifficulty[1] `
    -RegionWidth $rgHtDifficulty[2] -RegionHeight $rgHtDifficulty[3] -Scale 4 -SearchText $difficultySearch -ExactText $difficultyKey
  if ($difficultyPoint) {
    Focus-Game -Game $Game
    Click-ScreenPoint -X $difficultyPoint.X -Y $difficultyPoint.Y
    Write-RunLog "[사냥터] 1. 난이도 '$htDifficulty' 클릭"
    Start-Sleep -Milliseconds 900
    # 사후 검증: 클릭이 빗나가 다른 난이도로 바뀌지 않았는지 선택 강조로 확인 (첫 좌표 재사용)
    Confirm-DifficultySelected -Game $Game -ClickPoint $difficultyPoint -Label $htDifficulty | Out-Null
  } else {
    Write-RunLog "[경고] 난이도 '$htDifficulty' 글자를 찾지 못했습니다 (이 사냥터에 없는 난이도일 수 있음) - 현재 선택된 난이도로 진행합니다"
  }

  # 2. 은동전(사냥 임무)/더블 루팅 카드 설정 - 소탕 10개, 더블 루팅 +10개(합 20개).
  #    잔량 10~19개는 옵션에 따라 더블 루팅만 끄고 계속, 10개 미만이면 나가서 마칩니다.
  $effectiveCoin = $htUseCoin
  $effectiveLoot = ($htUseCoin -and $htDoubleLoot)
  if ($htUseCoin) {
    $coinBalance = Get-DgCoinBalance -Game $Game
    if ($null -ne $coinBalance) {
      if ($coinBalance -lt 10) {
        Exit-HuntingGroundExhausted -Game $Game -Reason "은동전 잔량 ${coinBalance}개 (소탕에 10개 필요) - 소진"
      } elseif ($effectiveLoot -and $coinBalance -lt 20) {
        if ($htLootFallback) {
          $effectiveLoot = $false
          Write-RunLog "[사냥터] 은동전 잔량 ${coinBalance}개 (더블 루팅 포함 20개 필요) - 더블 루팅만 끄고 소탕(10개)으로 계속합니다"
        } else {
          Exit-HuntingGroundExhausted -Game $Game -Reason "은동전 잔량 ${coinBalance}개 (더블 루팅 포함 20개 필요, '소탕만 계속' 옵션 꺼짐)"
        }
      }
    }
  }
  Set-DgToggleCard -Game $Game -Region $rgHtCardButton -AltRegion $rgHtCardButtonAlt -ClickPoint $ptHtCardButton -WantSelected $effectiveCoin -Label '은동전(사냥 임무)' | Out-Null
  # 더블 루팅은 소탕(은동전) 전제 기능이라 소탕을 사용할 때만 상태를 맞춥니다 (던전과 동일)
  if ($effectiveCoin) {
    Set-DgToggleCard -Game $Game -Region $rgHtLootButton -AltRegion $rgHtLootButtonAlt -ClickPoint $ptHtLootButton -WantSelected $effectiveLoot -Label '더블 루팅' | Out-Null

    # 입장 버튼의 공물 소모량(소탕 10 / 더블 루팅 20)으로 교차 검증합니다 (던전과 동일 영역).
    # 사냥터 화면에 소모량 표기가 없으면 읽기 실패로 건너뛰므로 무해합니다.
    Start-Sleep -Milliseconds 500
    $expectedCost = if ($effectiveLoot) { 20 } else { 10 }
    $actualCost = Get-DgTributeCost -Game $Game
    if ($null -eq $actualCost) {
      Write-RunLog "[사냥터] 공물 소모량을 읽지 못해 교차 검증을 건너뜁니다 (예상 ${expectedCost}개)"
    } elseif ($actualCost -eq $expectedCost) {
      Write-RunLog "[사냥터] 공물 소모량 ${actualCost}개 확인 (더블 루팅 $(if ($effectiveLoot) { '켬' } else { '끔' })과 일치)"
    } elseif ($actualCost -eq 10 -or $actualCost -eq 20) {
      Write-RunLog "[경고] 공물 소모량 불일치 (예상 ${expectedCost}, 실제 ${actualCost}) - 더블 루팅 버튼을 눌러 정정합니다"
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptHtLootButton[0] -ReferenceY $ptHtLootButton[1]
      Start-Sleep -Milliseconds 1100
      $recheck = Get-DgTributeCost -Game $Game
      if ($null -ne $recheck -and $recheck -eq $expectedCost) {
        Write-RunLog "[사냥터] 공물 소모량 ${recheck}개로 정정 확인"
      } else {
        Write-RunLog "[경고] 공물 소모량이 여전히 예상(${expectedCost})과 다릅니다 (실제 '$recheck') - 현재 상태로 진행합니다"
      }
    } else {
      Write-RunLog "[경고] 공물 소모량이 예상 밖입니다 (예상 ${expectedCost}, 실제 ${actualCost}) - OCR 오류 가능성이 있어 현재 상태로 진행합니다"
    }
  } else {
    # 역방향 검증: 미사용인데도 시작 버튼에 소모량(10/20)이 보이면 카드가 켜진 채 남은 것
    # (던전 2026-07-19 00:21 실측 사고와 동일 구조 - 카드 글자 깨짐 대비).
    # 사냥터 화면에 소모량 표기가 없으면 읽기 실패($null)로 건너뛰므로 무해합니다.
    Start-Sleep -Milliseconds 500
    $offCost = Get-DgTributeCost -Game $Game
    if ($null -ne $offCost -and ($offCost -eq 10 -or $offCost -eq 20)) {
      Write-RunLog "[경고] 은동전 미사용인데 시작 버튼에 소모량 ${offCost}개가 보입니다 - 은동전(사냥 임무) 카드를 눌러 해제합니다"
      # 상태 기반 해제 (던전 역방향 검증과 동일한 규칙 - 그쪽 주석 참고)
      $offCleared = $false
      $offClicks = 0
      for ($offTry = 1; $offTry -le 5; $offTry++) {
        if ($null -eq $offCost) {
          if (-not $script:screenCaptureFailing) { $offCleared = $true; break }
          Start-Sleep -Milliseconds 1500   # 캡처 실패 중 - 입력 없이 재확인
        } elseif ($offCost -eq 10 -or $offCost -eq 20) {
          if ($offClicks -ge 2) { break }
          $offClicks++
          Focus-Game -Game $Game
          Click-GamePoint -Game $Game -ReferenceX $ptHtCardButton[0] -ReferenceY $ptHtCardButton[1]
          Start-Sleep -Milliseconds 1100
        } else {
          break
        }
        $offCost = Get-DgTributeCost -Game $Game
      }
      if ($offCleared) {
        Write-RunLog '[사냥터] 소모량 표시 사라짐 - 은동전 미사용 확인'
      } elseif ($null -ne $offCost -and ($offCost -eq 10 -or $offCost -eq 20)) {
        throw "은동전 미사용 설정인데 은동전(사냥 임무)을 해제하지 못했습니다 (시작 버튼 소모량: ${offCost}개). 게임에서 카드를 직접 '도전'으로 바꾼 뒤 다시 시작해 주세요."
      } else {
        Write-RunLog "[경고] 카드 해제 확인이 불명확합니다 (소모량 판독: '$offCost') - 현재 상태로 진행합니다"
      }
    }
  }

  # 3. 입장 (매칭 방식별)
  if ($htMatching -eq '파티찾기') {
    Write-RunLog "[사냥터] 2. '파티 찾기' 클릭 - 파티 매칭을 기다립니다"
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ptDgPartyFind[0] -ReferenceY $ptDgPartyFind[1]
    Start-Sleep -Milliseconds 1200
    Resolve-DgEnterConfirmPopup -Game $Game | Out-Null
  } else {
    # 바로 입장: 첫 화면(입장하기 버튼)이 사라지는지 확인하며 재시도합니다.
    # 은동전이 부족해 입장이 막히면 옵션에 따라 공물 임무를 해제하고 이어갑니다.
    Write-RunLog '[사냥터] 2. 입장하기 클릭'
    $entered = $false
    $lootFallbackDone = $false
    for ($enterTry = 1; $enterTry -le 4; $enterTry++) {
      # 캡처 실패 중에는 입장 여부를 확인할 수 없는 채 클릭/시도 횟수만 소모되므로,
      # 입장 버튼 탐색을 복구 탐침 삼아 캡처가 돌아올 때까지 기다렸다가 진행합니다.
      while ($script:screenCaptureFailing) {
        Test-SafeStopDuringCaptureFail
        Start-Sleep -Seconds 2
        Find-HtEntryButtonPoint -Game $Game | Out-Null
      }
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptDgEnterFinal[0] -ReferenceY $ptDgEnterFinal[1]
      Start-Sleep -Milliseconds 1200
      Resolve-DgEnterConfirmPopup -Game $Game | Out-Null
      $stillEntry = [bool](Find-HtEntryButtonPoint -Game $Game)
      if ($stillEntry) {
        Start-Sleep -Seconds 2
        $stillEntry = [bool](Find-HtEntryButtonPoint -Game $Game)
      }
      # 캡처 실패 중에는 버튼 탐색이 무조건 실패($null)하므로 '입장됨'으로 오판하지 않습니다.
      if (-not $stillEntry -and -not $script:screenCaptureFailing) {
        $entered = $true
        break
      }
      # 잔량 읽기가 실패해 사전 확인을 건너뛴 경우의 예비: 입장이 막히면 '소탕만 계속'
      # 옵션에 따라 더블 루팅만 끄고 재시도합니다 (캡처 순단 중에는 발동하지 않음)
      if ($enterTry -ge 2 -and -not $script:screenCaptureFailing -and
          $effectiveLoot -and $htLootFallback -and -not $lootFallbackDone) {
        Write-RunLog '[사냥터] 입장 안 됨(은동전 부족 추정) - 더블 루팅만 끄고 소탕(10개)으로 재시도'
        Set-DgToggleCard -Game $Game -Region $rgHtLootButton -AltRegion $rgHtLootButtonAlt -ClickPoint $ptHtLootButton -WantSelected $false -Label '더블 루팅' | Out-Null
        $effectiveLoot = $false
        $lootFallbackDone = $true
      }
    }
    if (-not $entered) {
      # 은동전 부족으로 입장이 막힌 것으로 확인되면 사냥터에서 나가고 마칩니다 (사용자 결정)
      $finalBalance = Get-DgCoinBalance -Game $Game
      $neededNow = $(if ($effectiveLoot) { 20 } else { 10 })
      if ($htUseCoin -and $effectiveCoin -and $null -ne $finalBalance -and $finalBalance -lt $neededNow) {
        Exit-HuntingGroundExhausted -Game $Game -Reason "은동전 소진(잔량 ${finalBalance}개, 필요 ${neededNow}개)"
      }
      throw '입장하기가 진행되지 않습니다. 은동전 잔량 또는 입장 조건을 확인해 주세요.'
    }
  }

  # 4. 입장 완료 대기: 사냥터는 필드형이라 HUD로는 구분되지 않으므로,
  #    퀘스트 추적기에 사냥 임무('소탕'/'정찰')가 나타나는 것으로 판단합니다.
  Write-RunLog '[사냥터] 3. 사냥터 로딩 중...'
  Start-Sleep -Seconds 1
  $entryWaitSeconds = $(if ($htMatching -eq '파티찾기') { $timeoutPartyMatch } else { $timeoutEntry })
  Wait-ForScreen -Game $Game -TimeoutSeconds $entryWaitSeconds -Description '사냥터 입장 완료' -Condition {
    $questNow = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgQuestTracker[0] -ReferenceY $rgQuestTracker[1] `
        -RegionWidth $rgQuestTracker[2] -RegionHeight $rgQuestTracker[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
    ($questNow.Contains('소탕') -or $questNow.Contains('정찰'))
  }
  Write-RunLog '[사냥터] 4. 사냥터 입장 완료 감지'

  # 입장 후 키 입력 (자동출발/음식 - 어비스/던전과 동일한 설정 사용)
  Invoke-AfterEntryKeys -Game $Game -LogPrefix '[사냥터]'

  }  # end if (-not $insideAlready)

  # 5. 완료 대기 - 던전과 동일한 감지/안전장치(자동사냥 감시, 자동 부활, 컷신, 팝업)를 사용합니다.
  Write-RunLog '[사냥터] 5. 사냥 완료 화면 감지 대기 시작'
  $clearOutcome = Wait-ForDungeonClearScreen -Game $Game -TimeoutSeconds $timeoutClear -DungeonMode `
    -FindResultButton { Find-HtNewMissionPoint -Game $Game }
  if ($clearOutcome -eq 'clear') {
    Focus-Game -Game $Game
    Click-GamePoint -Game $Game -ReferenceX $ptClearCenter[0] -ReferenceY $ptClearCenter[1]
    Write-RunLog '[사냥터] 6. 사냥 완료 - 화면 터치'
  } else {
    Write-RunLog "[사냥터] 6. 완료 화면을 이미 지나친 상태($clearOutcome) - 결과 화면 처리로 진행"
  }

  }  # end if (-not $onResultScreen)

  # 7. 컷신을 넘기며 결과 화면(나가기/머무르기/새 임무 선택)을 기다립니다 (던전과 유사 구조)
  if (-not $onResultScreen) {
    Write-RunLog '[사냥터] 7. 결과 화면 대기 (컷신은 자동으로 넘김)'
  }
  $null = Wait-ForResultScreen -Game $Game -MissingMessage '사냥터 결과 화면(새 임무 선택 버튼)을 찾지 못했습니다.' `
    -FindRetryButton { Find-HtNewMissionPoint -Game $Game }
  Write-RunLog '[사냥터] 8. 결과 화면 확인 (나가기 / 머무르기 / 새 임무 선택)'

  # 8-1. 다음 임무 몫의 은동전이 없으면 '새 임무 선택'을 게임이 거부합니다
  #      ('다음 임무에 사용할 은동전이 부족해요' 안내 - 2026-07-18 01:05 실측).
  #      그래서 누르기 전에 잔량을 확인해 부족하면 여기서 나가기로 마칩니다.
  if ($htUseCoin) {
    $retryBalance = Get-DgCoinBalance -Game $Game
    if ($null -ne $retryBalance) {
      if ($retryBalance -lt 10) {
        Exit-HuntingGroundExhausted -Game $Game -Reason "은동전 잔량 ${retryBalance}개 (소탕에 10개 필요) - 소진"
      } elseif ($htDoubleLoot -and $retryBalance -lt 20 -and -not $htLootFallback) {
        Exit-HuntingGroundExhausted -Game $Game -Reason "은동전 잔량 ${retryBalance}개 (더블 루팅 포함 20개 필요, '소탕만 계속' 옵션 꺼짐)"
      }
    }
  }

  # 9. 안전 중지가 예약돼 있으면 나가기로 마치고, 아니면 '새 임무 선택'으로 첫 화면 복귀 후 반복합니다.
  Invoke-SafeStopExitIfRequested -Game $Game
  # '새 임무 선택' 클릭 → 첫 화면(입장하기) 복귀 대기.
  # 주의: 첫 화면에서는 같은 자리(797,655 부근)가 '파티 찾기' 버튼입니다. 전환 로딩 중에
  # '입장하기'가 아직 안 읽힌다고 같은 자리를 무조건 재클릭하면 파티 찾기가 눌려 의도치
  # 않은 재입장이 시작됩니다 (2026-07-17 23:51 실측 사고 - 검은 로딩 화면에서 시간 초과).
  # 그래서 결과 화면(새 임무 선택 버튼)이 그대로 보일 때만 다시 클릭하고, 전환 중에는
  # 기다리기만 합니다 (파티장 '입장 취소' 오클릭 방지와 같은 규칙).
  Focus-Game -Game $Game
  Click-GamePoint -Game $Game -ReferenceX $ptHtNewMission[0] -ReferenceY $ptHtNewMission[1]
  Write-RunLog "[사냥터] 9. '새 임무 선택' 클릭 - 첫 화면 복귀 대기"
  $returnDeadline = (Get-Date).AddSeconds(40)
  $returnedToEntry = $false
  while ((Get-Date) -lt $returnDeadline) {
    Start-Sleep -Seconds 2
    if ($script:screenCaptureFailing) {
      Test-SafeStopDuringCaptureFail
      $returnDeadline = (Get-Date).AddSeconds(40)
      continue
    }
    if (Find-HtEntryButtonPoint -Game $Game) {
      $returnedToEntry = $true
      break
    }
    # 가방이 차면 '새 임무 선택' 뒤에 아이템 정리 화면(정리 대상 → Space 정리하기)이
    # 끼어듭니다 (2026-07-18 00:14 실측). 게임 내 정리 규칙대로 정리하고 계속합니다.
    $cleanupText = (Get-GameOcrText -Game $Game) -replace '\s', ''
    # '탐험을 계속하시겠습니까?' 팝업(밖에서 진행할 퀘스트 안내)이 끼어들면 계속하기를
    # 선택합니다 - 이 팝업에서 Space 는 '나가기'라 절대 Space 로 넘기면 안 됩니다.
    if ($cleanupText.Contains('계속하')) {
      $contPoint = Find-GameTextPoint -Game $Game -ReferenceX $rgClearExit[0] -ReferenceY $rgClearExit[1] `
        -RegionWidth $rgClearExit[2] -RegionHeight $rgClearExit[3] -SearchText '계속하'
      Focus-Game -Game $Game
      if ($contPoint) {
        Click-ScreenPoint -X $contPoint.X -Y $contPoint.Y
      } else {
        Press-KeyOnce -VirtualKey ([byte]27)   # ESC = 계속하기 (버튼 지점을 못 찾은 경우 예비)
      }
      Write-RunLog "[사냥터] '탐험을 계속하시겠습니까?' 팝업 - 계속하기 선택"
      Start-Sleep -Seconds 1
      continue
    }
    if ($cleanupText.Contains('정리')) {
      Focus-Game -Game $Game
      Press-KeyOnce -VirtualKey ([byte]32)   # Space = 정리하기
      Write-RunLog '[사냥터] 아이템 정리 화면 감지 - Space로 정리하기'
      Start-Sleep -Seconds 2
      continue
    }
    if (Find-HtNewMissionPoint -Game $Game) {
      Write-RunLog "[사냥터] 결과 화면이 남아 있어 '새 임무 선택'을 다시 클릭합니다"
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptHtNewMission[0] -ReferenceY $ptHtNewMission[1]
    }
  }
  if (-not $returnedToEntry) {
    throw '새 임무 선택 후 사냥터 첫 화면(입장하기)이 확인되지 않습니다.'
  }
  Write-RunLog '[사냥터] 10. 첫 화면 복귀 확인 - 회차 완료'
  exit 0
}

# ============================================================
#  어비스 '파티(파티원)' 전용 사이클 (2026-07-17 실측 기반)
#  파티원은 ESC/어비스 메뉴 이동 없이 필드에서 대기합니다. 파티장이 입장하기를
#  누르면 파티 패널에 '준비 완료' 버튼이 활성화되고, 누른 뒤 전원이 준비되면
#  자동 입장됩니다. 클리어 후에는 각자 나가기를 눌러 필드로 돌아오고(사용자
#  확인), 다음 회차는 다시 '준비 완료' 대기부터 반복합니다.
#  '준비 완료' 버튼은 파티장의 입장하기/입장 취소와 같은 자리(하단 우측)라
#  글자 영역(rgPartyEnterBtn)과 클릭 지점(ptPartyEnter)을 그대로 재사용합니다.
# ============================================================
function Invoke-AbyssPartyMemberCycle {
  param([System.Diagnostics.Process]$Game)

  # --- 시작 상태 재개: 이미 던전 안/클리어/보상 화면이면 그 지점부터 이어갑니다 ---
  $skipToFinish = $false
  $inDungeon = $false
  if (Test-ExitButton -Game $Game) {
    Write-RunLog '[파티원] 시작: 보상 화면(나가기) 감지 - 마무리부터 진행'
    $skipToFinish = $true
  } elseif (Test-DungeonClearPrompt -Game $Game) {
    Write-RunLog '[파티원] 시작: 클리어 화면 감지 - 마무리부터 진행'
    Invoke-ClickUntil -Game $Game -Point $ptClearCenter -Description '클리어 화면 터치(나가기 버튼 표시)' `
      -TimeoutSeconds ($timeoutExit + 15) -ReclickEverySeconds 3 -Condition { Test-ExitButton -Game $Game }
    $skipToFinish = $true
  } elseif (Test-InDungeonQuest -Game $Game) {
    Write-RunLog '[파티원] 시작: 던전 입장 상태 감지 - 클리어 대기부터 진행'
    $inDungeon = $true
  }

  if (-not $skipToFinish) {
    if (-not $inDungeon) {
      # --- 1. 파티장의 입장 시작 대기 → '준비 완료' 클릭 → 자동 입장 대기 (단일 루프) ---
      # 파티장의 회차 사이 복귀/재진입이 몇 분 걸릴 수 있어 매칭 대기보다 길게 기다립니다.
      $memberWaitSeconds = [Math]::Max($timeoutPartyMatch, 1800)
      Write-RunLog "[파티원] 1. 파티장의 입장 시작 대기 중... ('준비 완료' 버튼이 뜨면 클릭, 최대 $memberWaitSeconds초)"
      $memberDeadline = (Get-Date).AddSeconds($memberWaitSeconds)
      $readyClicked = $false
      while ($true) {
        if ((Get-Date) -ge $memberDeadline) {
          throw "파티장의 입장 시작을 기다리다 시간을 초과했습니다 (${memberWaitSeconds}초) - 파티 상태와 파티장 쪽 자동화를 확인해 주세요."
        }
        if (Test-InDungeonQuest -Game $Game) { break }
        # '준비 완료'를 누르기 전(순수 대기 중)에만 안전 중지 예약을 소비합니다 (필드 = 안전 지점)
        if (-not $readyClicked -and (Test-Path -LiteralPath $safeStopFlagPath)) {
          Remove-Item -LiteralPath $safeStopFlagPath -Force -ErrorAction SilentlyContinue
          Write-RunLog '[완료] 안전 중지 예약 확인 - 파티원 대기 상태에서 자동화를 마칩니다 (회차 미완료)'
          exit 4
        }
        $memberBtnText = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgPartyEnterBtn[0] -ReferenceY $rgPartyEnterBtn[1] `
          -RegionWidth $rgPartyEnterBtn[2] -RegionHeight $rgPartyEnterBtn[3] -Scale 4 -Engine $ocrKoreanEngine) -replace '\s', ''
        if ($memberBtnText -match '완료' -and $memberBtnText -notmatch '취소') {
          # '준비 완료' 활성 - 클릭. 누르면 '준비 취소'로 바뀐다고 보고 '취소'가 보이면 더
          # 누르지 않습니다 (파티장의 '입장 취소'와 같은 오클릭 방지 규칙). 파티장이 입장을
          # 취소했다가 다시 시작하면 버튼이 되살아나므로 그때는 이 분기가 다시 클릭합니다.
          Focus-Game -Game $Game
          Click-GamePoint -Game $Game -ReferenceX $ptPartyEnter[0] -ReferenceY $ptPartyEnter[1]
          Write-RunLog "[파티원] 2. '준비 완료' 클릭 - 전원 준비되면 자동 입장"
          $readyClicked = $true
        }
        Start-Sleep -Seconds 3
      }
      Write-RunLog '[파티원] 3. 던전 입장 완료 감지'
    }

    # --- 2. 입장 직후 키 입력 (자동출발 등 - 어비스 본류와 동일) ---
    Invoke-AfterEntryKeys -Game $Game -LogPrefix '[파티원]'

    # --- 3. 클리어 대기 → 터치 → 나가기 (어비스 본류와 동일한 헬퍼 재사용) ---
    Write-RunLog '[파티원] 4. 클리어 화면 감지 대기 시작'
    $clearOutcome = Wait-ForDungeonClearScreen -Game $Game -TimeoutSeconds $timeoutClear
    if ($clearOutcome -eq 'clear') {
      Write-RunLog '[파티원] 5. 클리어 화면 터치'
      Invoke-ClickUntil -Game $Game -Point $ptClearCenter -Description '클리어 화면 터치(나가기 버튼 표시)' `
        -TimeoutSeconds ($timeoutExit + 15) -ReclickEverySeconds 3 -Condition { Test-ExitButton -Game $Game }
      Write-RunLog '[파티원] 6. 나가기 버튼 감지'
    }
    if ($clearOutcome -eq 'selection') {
      # 사용자가 직접 화면을 넘겨 선택 화면까지 간 예외 상황 - 나가기 단계가 없습니다
      Write-RunLog '[완료] 파티원 회차 완료 (선택 화면 상태)'
      exit 0
    }
  }

  # --- 4. 나가기 → 필드 복귀 확인. 파티원은 어비스 선택 화면으로 복귀하지 않습니다 ---
  Focus-Game -Game $Game
  Click-GamePoint -Game $Game -ReferenceX $ptExitButton[0] -ReferenceY $ptExitButton[1]
  Write-RunLog '[파티원] 7. 나가기 클릭'
  Wait-ForScreen -Game $Game -TimeoutSeconds $timeoutHud -Description '던전 밖(필드) 복귀' -Condition {
    Test-HomeEndEscHud -Game $Game
  }
  Write-RunLog '[완료] 파티원 회차 완료 - 필드에서 다음 입장을 기다립니다'
  exit 0
}

function Return-ToAbyssSelection {
  param([System.Diagnostics.Process]$Game)

  # 던전 밖에서 어비스 선택 화면으로 돌아가는 과정을 '상태 기반'으로 반복합니다.
  # 매 반복마다 현재 화면을 다시 판단해 필요한 조작만 하므로, ESC 클릭이 빗나가거나
  # 사용자가 화면을 조작해 뒤로 가더라도 스스로 다시 시도해 복구합니다.
  $deadline = (Get-Date).AddSeconds($timeoutHud + $timeoutAbyssMenu + $timeoutAbyssSelect)
  $loggedHud = $false
  $loggedMenu = $false
  $lastFocus = Get-Date
  $unknownSince = $null   # '알 수 없는 화면' 상태가 시작된 시각 (오클릭으로 열린 우편함 등 복구용)
  $xAttempts = 0          # 닫기(X) 후보 순환 인덱스
  $stellaHandled = 0      # 복귀 중 스텔라 픽 처리 횟수 (무한 클릭 방지 상한용)

  while ((Get-Date) -lt $deadline) {
    # 0) 화면 캡처가 안 되는 동안은 판단이 불가능하므로 제한 시간을 멈추고 기다립니다.
    if ($script:screenCaptureFailing) {
      Test-SafeStopDuringCaptureFail
      $deadline = (Get-Date).AddSeconds($timeoutHud + $timeoutAbyssMenu + $timeoutAbyssSelect)
      Start-Sleep -Milliseconds 700
      # 아래 상태 검사(OCR)는 계속 시도해 복구 여부를 확인합니다.
    }

    # 1) 이미 어비스 선택 화면이면 완료
    if (Test-AbyssSelectionScreen -Game $Game) {
      Write-RunLog '[어비스] 18. 선택 화면 복귀 확인'
      return
    }

    # 2) ESC 메뉴가 열려 있으면(어비스 항목 보임) 어비스 클릭
    if (Test-AbyssMenu -Game $Game) {
      $unknownSince = $null
      if (-not $loggedMenu) { Write-RunLog '[어비스] 16. 어비스 메뉴 감지'; $loggedMenu = $true }
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptAbyssMenu[0] -ReferenceY $ptAbyssMenu[1]
      Write-RunLog '[어비스] 17. 어비스 메뉴 클릭'
      Start-Sleep -Seconds 2
      continue
    }

    # 3) 던전 밖 Home/End/ESC HUD가 보이면 ESC를 눌러 메뉴 열기
    if (Test-HomeEndEscHud -Game $Game) {
      $unknownSince = $null
      if (-not $loggedHud) { Write-RunLog '[어비스] 14. 던전 밖(HUD) 확인'; $loggedHud = $true }
      # 안전 중지가 예약된 경우: 어차피 멈출 것이므로 어비스 선택 화면까지 복귀하지 않고
      # 던전 밖이 확인된 이 시점에서 회차를 마칩니다.
      if (Test-Path -LiteralPath $safeStopFlagPath) {
        # 신호 파일은 워커가 소비(삭제)합니다 (남은 파일로 인한 헛 조기 종료 방지)
        Remove-Item -LiteralPath $safeStopFlagPath -Force -ErrorAction SilentlyContinue
        Write-RunLog '[완료] 안전 중지 예약 확인 - 던전 밖(HUD) 확인 시점에서 회차를 마칩니다'
        exit 0
      }
      # 공지 게시판 팝업이 화면을 덮고 있으면(HUD는 가장자리로 계속 보임) ESC 클릭이
      # 팝업에 막혀 헛돌기만 합니다 - 먼저 팝업 우상단 X를 눌러 닫습니다
      # (2026-07-19 06:42 hyodong 실측: 6시 리셋 후 이 팝업으로 ESC 18회 헛클릭 → 시간 초과)
      if (Test-NoticeBoardPopup -Game $Game) {
        Focus-Game -Game $Game
        Click-GamePoint -Game $Game -ReferenceX $ptNoticeClose[0] -ReferenceY $ptNoticeClose[1]
        Write-RunLog '[어비스] 공지 게시판 팝업 감지 - X로 닫기'
        Start-Sleep -Seconds 2
        continue
      }
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptEscButton[0] -ReferenceY $ptEscButton[1]
      Write-RunLog '[어비스] 15. ESC 클릭'
      Start-Sleep -Seconds 2
      continue
    }

    # 4) 보상 화면(나가기 버튼)이 아직 남아 있으면 나가기 클릭 (앞선 클릭이 빗나간 경우 복구)
    if (Test-ExitButton -Game $Game) {
      $unknownSince = $null
      Focus-Game -Game $Game
      Click-GamePoint -Game $Game -ReferenceX $ptExitButton[0] -ReferenceY $ptExitButton[1]
      Write-RunLog '[어비스] 13. 나가기 클릭 (복구 재시도)'
      Start-Sleep -Seconds 2
      continue
    }

    # 5) 어느 상태도 아니면 출석/이벤트 화면이 덮였을 수 있으므로 '건너뛰기'/'확인' 버튼을
    #    찾아 클릭합니다 (6시 리셋 이벤트가 복귀 도중 뜨는 경우 대응. 없으면 그냥 대기).
    if (-not $script:screenCaptureFailing) {
      if (Invoke-EventSkipOrConfirm -Game $Game -LogPrefix '복귀 중 ') {
        $unknownSince = $null
        continue
      }

      # 5-1) 오늘의 스텔라 픽(스텔라그램) 팝업이 복귀 중에 뜨면 바로 처리합니다.
      #      기존에는 '알 수 없는 화면 20초 → X 닫기'로 느리게 넘겼고 X로 닫으면 오늘 픽을
      #      고르지 못할 수 있었습니다 (실측 2026-07-18 06:00). Clear-EventOverlay 와 같은
      #      방식: 1단계(카드 선택) → 2단계(확정 버튼). 상한(5회)을 넘으면 X 폴백에 맡깁니다.
      if ($stellaHandled -lt 5) {
        $stellaTitleNow = (Get-GameRegionOcrText -Game $Game -ReferenceX $rgStellaTitle[0] -ReferenceY $rgStellaTitle[1] `
          -RegionWidth $rgStellaTitle[2] -RegionHeight $rgStellaTitle[3] -Scale 3 -Engine $ocrKoreanEngine) -replace '\s', ''
        if ($stellaTitleNow.Contains('스텔라')) {
          $stellaHandled++
          Focus-Game -Game $Game
          Click-GamePoint -Game $Game -ReferenceX $ptStellaCard[0] -ReferenceY $ptStellaCard[1]
          Write-RunLog '[안내] 복귀 중 스텔라 픽 감지 - 가운데 카드 선택'
          Start-Sleep -Seconds 2
          $unknownSince = $null
          continue
        }
        $stellaBtnNow = Find-GameTextPoint -Game $Game -ReferenceX $rgStellaPickBtn[0] -ReferenceY $rgStellaPickBtn[1] `
          -RegionWidth $rgStellaPickBtn[2] -RegionHeight $rgStellaPickBtn[3] -SearchText '스텔라'
        if ($stellaBtnNow) {
          $stellaHandled++
          Focus-Game -Game $Game
          Click-ScreenPoint -X $stellaBtnNow.X -Y $stellaBtnNow.Y
          Write-RunLog '[안내] 복귀 중 스텔라 픽 2단계 - 확정 버튼 클릭'
          Start-Sleep -Seconds 2
          $unknownSince = $null
          continue
        }
      }

      # 5.5) 알 수 없는 화면이 계속되면(오클릭으로 열린 우편함/전체 화면 UI 등 - 실측 2026-07-17)
      #      알려진 닫기(X) 위치를 순환 클릭해 원래 화면으로 복구를 시도합니다.
      #      단, 나가기 직후 화면 전환(페이드/로딩)도 몇 초간 '알 수 없음'으로 보이므로
      #      반드시 20초 이상 지속될 때만 발동합니다
      #      (실측 2026-07-17 05:18: 횟수 기준으로 조기 발동해 필드의 미니맵(1229,67)을 오클릭).
      if ($null -eq $unknownSince) { $unknownSince = Get-Date }
      if (((Get-Date) - $unknownSince).TotalSeconds -ge 20) {
        $xCandidates = @(@(1229, 67), @(1090, 137), @(959, 180))
        $xPick = $xCandidates[$xAttempts % $xCandidates.Count]
        $xAttempts++
        Focus-Game -Game $Game
        Click-GamePoint -Game $Game -ReferenceX $xPick[0] -ReferenceY $xPick[1]
        Write-RunLog "[안내] 복귀 중 알 수 없는 화면 20초 지속 - 닫기(X) 후보($($xPick[0]),$($xPick[1])) 클릭"
        Start-Sleep -Seconds 2
        continue
      }
    }

    # 6) 로딩/전환 중이거나 게임 창이 가려진 경우 - 잠시 기다렸다 재확인.
    #    감지가 계속 안 되면 게임 창을 주기적으로 앞으로 가져옵니다.
    if ($refocusEverySeconds -gt 0 -and
        ((Get-Date) - $lastFocus).TotalSeconds -ge $refocusEverySeconds) {
      if (Invoke-AutoRefocus -Game $Game) { $lastFocus = Get-Date }
    }
    Start-Sleep -Milliseconds 700
  }

  throw '어비스 선택 화면 복귀 대기 시간이 초과됐습니다.'
}

function Get-KeyDisplayName {
  param([int]$VirtualKey)

  # 로그 표시용 키 이름. 자주 쓰는 키만 이름으로, 나머지는 코드로 표시합니다.
  if ($VirtualKey -eq 32) { return 'Space' }
  if (($VirtualKey -ge 65 -and $VirtualKey -le 90) -or ($VirtualKey -ge 48 -and $VirtualKey -le 57)) {
    return [string][char]$VirtualKey
  }
  return ('VK 0x{0:X2}' -f $VirtualKey)
}

function Press-KeyOnce {
  param([byte]$VirtualKey)

  [HoneyNogiInput]::keybd_event($VirtualKey, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  [HoneyNogiInput]::keybd_event($VirtualKey, 0, 2, [UIntPtr]::Zero)
}

try {
  $game = Get-GameProcess
  Write-RunLog "[준비] 게임 확인: PID $($game.Id)"

  # ===== 적용 설정 스냅샷 (로그 파일 전용) =====
  # GUI 화면에는 표시되지 않고([설정] 줄은 GUI가 건너뜀) 로그 파일에만 남습니다.
  # 다른 사용자의 오류 세트(error_*.log)만 받아도 반복/콘텐츠/상세/기능 설정을
  # 그대로 볼 수 있게 하기 위한 분석용 기록입니다. 좌표/영역 섹션은 제외합니다.
  try {
    $repeatInfo = [string]$env:HONEYNOGI_REPEAT_INFO
    if ([string]::IsNullOrWhiteSpace($repeatInfo)) { $repeatInfo = '(GUI 정보 없음 - 워커 단독 실행)' }
    $appVersionInfo = [string]$env:HONEYNOGI_APP_VERSION
    if ([string]::IsNullOrWhiteSpace($appVersionInfo)) { $appVersionInfo = '?' }
    Write-RunLog "[설정] 꿀비노기 v$appVersionInfo, 콘텐츠 '$contentCategory', 반복 $repeatInfo, coordsVersion $(Get-ConfigValue $config @('coordsVersion') '?')"
    foreach ($sectionName in @('dungeons', 'normalDungeon', 'huntingGround', 'timeoutsSeconds', 'afterEntry', 'revive', 'rdp', 'window', 'diagnostics')) {
      $section = $config.$sectionName
      if ($null -eq $section) { continue }
      # 설명용 '_' 키와 부피 큰 profiles(좌표)는 빼고 실제 값만 한 줄 JSON으로 남깁니다
      $clean = [ordered]@{}
      foreach ($prop in $section.PSObject.Properties) {
        if ($prop.Name -like '_*' -or $prop.Name -eq 'profiles') { continue }
        $clean[$prop.Name] = $prop.Value
      }
      if ($clean.Count -gt 0) {
        Write-RunLog "[설정] ${sectionName}: $($clean | ConvertTo-Json -Compress -Depth 4)"
      }
    }
  } catch {
    Write-RunLog "[설정] 스냅샷 기록 실패: $($_.Exception.Message)"
  }

  Focus-Game -Game $game

  # 게임 창 정렬: RDP 재접속·배율 변화·콘솔 전환 등으로 창 크기가 바뀌면
  # 감지 좌표가 어긋나므로 매 사이클 시작 시 창을 보정합니다.
  #  - nearest 모드(기본): 사용자가 조절한 크기를 최대한 유지하고 "비율만" 기준(1272:717)에 맞춤.
  #                        창이 화면 밖으로 나가 있으면 화면 안으로 밀어 넣음.
  #  - fixed 모드        : config 의 x, y, width, height 로 항상 고정.
  # (게임이 "창 모드"일 때만 동작합니다)
  if ($windowNormalize) {
    $normalizeRect = New-Object HoneyNogiInput+RECT
    if ([HoneyNogiInput]::GetWindowRect($game.MainWindowHandle, [ref]$normalizeRect)) {
      $currentWidth = $normalizeRect.Right - $normalizeRect.Left
      $currentHeight = $normalizeRect.Bottom - $normalizeRect.Top
      $currentX = $normalizeRect.Left
      $currentY = $normalizeRect.Top
      # 작업 영역(작업표시줄 제외) 기준으로 배치합니다. 창이 작업표시줄과 겹치면
      # 하단 OCR 영역(클리어 문구/입장·나가기 버튼)이 게임 대신 작업표시줄을 읽고,
      # 하단 클릭도 작업표시줄에 먹히기 때문입니다.
      $workArea = New-Object HoneyNogiInput+RECT
      if ([HoneyNogiInput]::SystemParametersInfo(0x0030, 0, [ref]$workArea, 0)) {
        $workX = $workArea.Left
        $workY = $workArea.Top
        $workW = $workArea.Right - $workArea.Left
        $workH = $workArea.Bottom - $workArea.Top
      } else {
        $workX = 0
        $workY = 0
        $workW = [HoneyNogiInput]::GetSystemMetrics(0)
        $workH = [HoneyNogiInput]::GetSystemMetrics(1)
      }

      if ($windowMode -eq 'fixed') {
        $targetWidth = $windowWidth
        $targetHeight = $windowHeight
        $targetX = $windowX
        $targetY = $windowY
        $sizeOk = ($currentWidth -eq $targetWidth -and $currentHeight -eq $targetHeight)
      } elseif ($windowMode -eq 'recommended') {
        # 권장 크기(GUI '권장 창 크기' 체크): OCR 실측 기준(1272x717)의 깔끔한 배율로 맞춰
        # 글자 렌더링이 실측과 일치하게 합니다.
        #  - 작업 영역이 1.5배(1908x1076)를 '여유 있게' 담을 수 있으면(QHD 이상) 1908x1076
        #  - 그 외(FHD 포함)는 기준 1.0배(1272x717) - 가장 작으면서 인식이 정확한 크기
        # (FHD에서 1908은 화면을 거의 꽉 채워 불편하므로 여유 조건을 둡니다)
        if ($workW -ge 2100 -and $workH -ge 1150) {
          $targetWidth = 1908
          $targetHeight = 1076
        } else {
          $targetWidth = 1272
          $targetHeight = 717
        }
        $targetX = [Math]::Min([Math]::Max($currentX, $workX), [Math]::Max($workX + $workW - $targetWidth, $workX))
        $targetY = [Math]::Min([Math]::Max($currentY, $workY), [Math]::Max($workY + $workH - $targetHeight, $workY))
        $sizeOk = ([Math]::Abs($currentWidth - $targetWidth) -le 4 -and
                   [Math]::Abs($currentHeight - $targetHeight) -le 4)
      } else {
        # nearest: 현재 너비를 유지하되 높이를 기준 비율로 계산.
        # 창이 기준 크기(1272)보다 작으면 글자가 작아져 OCR 오독이 생기므로
        # 최소한 기준 크기까지 키웁니다 (작업 영역 폭은 넘지 않음).
        $targetWidth = [Math]::Max($currentWidth, $referenceWidth)
        $targetWidth = [Math]::Min($targetWidth, $workW)
        $targetHeight = [int][Math]::Round($targetWidth * $referenceHeight / $referenceWidth)
        if ($targetHeight -gt $workH) {
          $targetHeight = $workH
          $targetWidth = [int][Math]::Round($targetHeight * $referenceWidth / $referenceHeight)
        }
        # 위치는 유지하되 작업 영역 밖(작업표시줄 포함)으로 나가지 않게만 보정
        $targetX = [Math]::Min([Math]::Max($currentX, $workX), [Math]::Max($workX + $workW - $targetWidth, $workX))
        $targetY = [Math]::Min([Math]::Max($currentY, $workY), [Math]::Max($workY + $workH - $targetHeight, $workY))
        # 몇 픽셀 수준의 오차는 무시해 불필요한 리사이즈를 막습니다
        $sizeOk = ([Math]::Abs($currentWidth - $targetWidth) -le 4 -and
                   [Math]::Abs($currentHeight - $targetHeight) -le 4)
      }

      $positionOk = ($currentX -eq $targetX -and $currentY -eq $targetY)
      if (-not ($sizeOk -and $positionOk)) {
        [HoneyNogiInput]::MoveWindow($game.MainWindowHandle, $targetX, $targetY, $targetWidth, $targetHeight, $true) | Out-Null
        Start-Sleep -Milliseconds 800
        Write-RunLog "[준비] 게임 창 정렬($windowMode): ${currentWidth}x${currentHeight}@($currentX,$currentY) -> ${targetWidth}x${targetHeight}@($targetX,$targetY)"
      }
    }
  }

  # 시작 시 화면 캡처가 안 되는 상태(원격 데스크톱 창 최소화 등)면 복구될 때까지 기다립니다.
  $startExitDetected = Test-ExitButton -Game $game
  while ($script:screenCaptureFailing) {
    Test-SafeStopDuringCaptureFail
    Start-Sleep -Seconds 2
    $startExitDetected = Test-ExitButton -Game $game
  }

  # 아침 6시 리셋 후 뜨는 출석/이벤트/데일리 팝업(스텔라 픽 등)이 화면을 덮고 있으면
  # 자동으로 넘깁니다. 던전/사냥터 흐름도 이 화면에 막혀 시작하지 못하므로
  # 콘텐츠 분기보다 먼저 처리합니다. (넘긴 뒤에는 시작 상태를 다시 읽습니다)
  if (Clear-EventOverlay -Game $game) {
    $startExitDetected = Test-ExitButton -Game $game
  }

  # 파티(파티원) 매칭은 흐름이 완전히 다릅니다: 메뉴 이동 없이 필드에서 '준비 완료'만
  # 담당하고, 클리어 후에도 선택 화면으로 복귀하지 않습니다 (전용 사이클 내부에서 종료).
  if ($contentCategory -ne 'dungeon' -and $contentCategory -ne 'hunting' -and
      $dungeonMode -eq 'party' -and $abyssMatching -eq '파티(파티원)') {
    Invoke-AbyssPartyMemberCycle -Game $game
  }

  # 콘텐츠 선택이 '던전'/'사냥터'면 각 전용 흐름으로 진행합니다 (아래 어비스 흐름과 분리).
  # 이 화면들은 어비스의 '알 수 없는 화면' 처리에 걸리면 안 되므로 이 분기가 먼저 옵니다.
  if ($contentCategory -eq 'dungeon') {
    Invoke-NormalDungeonCycle -Game $game
  }
  if ($contentCategory -eq 'hunting') {
    Invoke-HuntingGroundCycle -Game $game
  }

  # 이전 실행이 ESC 메뉴가 열린 채 끝났을 수 있으므로, 메뉴가 열려 있으면
  # 먼저 어비스 선택 화면으로 복귀부터 처리합니다.
  if (-not $startExitDetected -and (Test-AbyssMenu -Game $game)) {
    Write-RunLog '[어비스] 시작: ESC 메뉴 감지 - 선택 화면으로 복귀부터 진행'
    Return-ToAbyssSelection -Game $game
    Write-RunLog '[완료] 어비스 선택 화면 복귀 완료 (준비 실행 - 회차로 세지 않음)'
    # 던전을 돌지 않고 화면 복귀만 한 '준비 실행'은 코드 10으로 끝냅니다.
    # GUI가 이를 회차로 세지 않고 곧바로 본 회차를 시작하므로, 횟수 지정 모드에서
    # 실제 던전 실행 횟수가 부족해지지 않습니다.
    exit 10
  }

  if ($startExitDetected) {
    Write-RunLog '[어비스] 시작: 보상 화면(나가기) 감지 - 마무리부터 진행'
    Click-GamePoint -Game $game -ReferenceX $ptExitButton[0] -ReferenceY $ptExitButton[1]
    Write-RunLog '[어비스] 13. 나가기 클릭'
    Return-ToAbyssSelection -Game $game
    Write-RunLog '[완료] 어비스 선택 화면 복귀 완료'
    # 이전 회차의 클리어를 실제로 마무리한 실행이므로 정상 완료(코드 0)로 계상합니다
    exit 0
  }

  if (Test-DungeonClearPrompt -Game $game) {
    Write-RunLog '[어비스] 시작: 클리어 화면 감지 - 마무리부터 진행'
    Write-RunLog '[어비스] 11. 클리어 화면 터치'
    # 등급 연출 중에는 터치가 무시될 수 있어(다른 PC 실측: 터치 후에도 '화면을 터치'가
    # 그대로 남음) 나가기 버튼이 보일 때까지 3초 간격으로 다시 터치합니다.
    Invoke-ClickUntil -Game $game -Point $ptClearCenter -Description '클리어 화면 터치(나가기 버튼 표시)' `
      -TimeoutSeconds ($timeoutExit + 15) -ReclickEverySeconds 3 -Condition { Test-ExitButton -Game $game }
    Write-RunLog '[어비스] 12. 나가기 버튼 감지'
    Focus-Game -Game $game
    Click-GamePoint -Game $game -ReferenceX $ptExitButton[0] -ReferenceY $ptExitButton[1]
    Write-RunLog '[어비스] 13. 나가기 클릭'
    Return-ToAbyssSelection -Game $game
    Write-RunLog '[완료] 어비스 선택 화면 복귀 완료'
    # 이전 회차의 클리어를 실제로 마무리한 실행이므로 정상 완료(코드 0)로 계상합니다
    exit 0
  }

  # 게임플레이 화면(HUD 표시) 중 '필드(던전 밖)'에 서 있는 상태면, 카드 클릭을 시도하기 전에
  # 먼저 ESC → 어비스 메뉴를 통해 어비스 선택 화면으로 이동합니다 (매크로 시작 기본 동선).
  # 던전 안이면 이 분기를 건너뛰고 아래의 '던전 입장 상태' 재개 흐름을 그대로 탑니다.
  if ((Test-HomeEndEscHud -Game $game) -and -not (Test-InDungeonQuest -Game $game)) {
    Write-RunLog '[어비스] 시작: 필드 상태 감지 - ESC → 어비스로 선택 화면 이동'
    Return-ToAbyssSelection -Game $game
    Write-RunLog '[완료] 어비스 선택 화면 복귀 완료 (준비 실행 - 회차로 세지 않음)'
    # 화면 복귀만 수행한 준비 실행: 회차로 세지 않도록 코드 10으로 종료 (위 ESC 메뉴 분기와 동일)
    exit 10
  }

  if (Test-DungeonEntered -Game $game) {
    Write-RunLog '[어비스] 시작: 던전 안 상태 감지 - 클리어 대기부터 재개'
  } else {
    # 시작 시 이미 어떤 던전의 상세 화면이 열려 있는지 "제목"으로 판단합니다.
    # (혼자하기/함께하기 어느 탭이든 제목은 항상 표시되므로 탭 상태와 무관하게 동작)
    # 다른 던전의 상세 화면이면 뒤로가기(<)로 선택 화면에 나간 뒤 올바른 카드부터 다시 진행합니다.
    $needCardClick = $true
    $currentTitle = Get-DetailTitleText -Game $game
    $isKnownDetail = $false
    foreach ($titleKeyword in $allDungeonKeywords) {
      if ($currentTitle.Contains($titleKeyword)) { $isKnownDetail = $true; break }
    }
    if ($isKnownDetail) {
      if ($currentTitle.Contains($dungeonMatch)) {
        $needCardClick = $false
      } else {
        Write-RunLog "[어비스] 시작: 다른 던전 상세 화면 감지 - 뒤로 나가서 다시 선택"
        Focus-Game -Game $game
        Click-GamePoint -Game $game -ReferenceX $ptDetailBack[0] -ReferenceY $ptDetailBack[1]
        Wait-ForScreen -Game $game -TimeoutSeconds $timeoutAbyssSelect -Description '어비스 던전 선택 화면' -Condition {
          Test-AbyssSelectionScreen -Game $game
        }
      }
    }
    if ($needCardClick) {
      Write-RunLog "[어비스] 1. $selectedDungeon 카드 클릭"
      Invoke-ClickUntil -Game $game -Point $dungeonCard -Description "$selectedDungeon 상세 화면" `
        -TimeoutSeconds $timeoutDetail -Condition { Test-DetailTitleMatches -Game $game }
    }
    Write-RunLog "[어비스] 2. $selectedDungeon 상세 화면 확인"

    # 미개발 던전: 상세 화면 진입까지만 지원하고 여기서 정상 종료합니다(종료 코드 3).
    if ($dungeonStage -ne 'full') {
      Write-RunLog "[안내] $selectedDungeon 은(는) 상세 화면 진입까지만 구현되어 있습니다. 이후 자동화는 미개발이라 여기서 종료합니다."
      exit 3
    }

    # 난이도 선택 동작 (설정된 난이도가 있으면 상세 화면에서 글자를 OCR로 찾아 클릭).
    # 혼자하기/함께하기 공용 - 사람이 하는 순서처럼 이동/입장 전에 먼저 난이도를 확정합니다.
    # (지옥1 등 난이도가 새로 추가되어 버튼 위치가 바뀌어도 글자 탐색이라 그대로 동작합니다.
    #  이미 선택돼 있는 난이도를 다시 클릭해도 부작용이 없어 상태 확인 없이 클릭합니다.)
    $selectDungeonDifficulty = {
      if ($dungeonDifficulty) {
        $difficultyKey = $dungeonDifficulty -replace '\s', ''
        $difficultySearch = $difficultyKey.Substring(0, [Math]::Min(2, $difficultyKey.Length))
        # 정확 일치 우선: '지옥1'을 찾을 때 '지옥10'을 잘못 잡지 않도록 단어 전체 일치를 먼저 봅니다.
        $difficultyPoint = Find-GameTextPoint -Game $game -ReferenceX $rgDifficultyTabs[0] -ReferenceY $rgDifficultyTabs[1] `
          -RegionWidth $rgDifficultyTabs[2] -RegionHeight $rgDifficultyTabs[3] -SearchText $difficultySearch -ExactText $difficultyKey
        if ($difficultyPoint) {
          Focus-Game -Game $game
          Click-ScreenPoint -X $difficultyPoint.X -Y $difficultyPoint.Y
          Write-RunLog "[어비스] 4. 난이도 '$dungeonDifficulty' 클릭"
          Start-Sleep -Milliseconds 800
          # 사후 검증: 클릭이 빗나가 다른 난이도로 바뀌지 않았는지 선택 강조로 확인 (첫 좌표 재사용)
          Confirm-DifficultySelected -Game $game -ClickPoint $difficultyPoint -Label $dungeonDifficulty | Out-Null
        } else {
          Write-RunLog "[경고] 상세 화면에서 난이도 '$dungeonDifficulty' 글자를 찾지 못했습니다 - 현재 선택된 난이도로 진행합니다"
        }
      }
    }

    # 입장 방식 탭 클릭: 혼자하기는 명시적으로 탭을 한 번 클릭해 확정한 뒤 입장합니다.
    # 함께하기는 '우연한 만남'/'파티찾기'/'파티(파티장)' 세 매칭 방식을 지원합니다.
    if ($dungeonMode -eq 'party') {
      Click-GamePoint -Game $game -ReferenceX $ptPartyTab[0] -ReferenceY $ptPartyTab[1]
      Write-RunLog '[어비스] 3. 함께하기 탭 클릭'
      # 함께하기 화면(하단 입장하기 버튼)이 뜰 때까지 대기.
      # 캐릭터가 던전에서 멀면 '입장하기' 대신 '이동하기' 단일 버튼이 표시되므로
      # (실측 2026-07-17: 다른 PC에서 함께하기 탭인데 혼자하기 버튼 영역에 '이동') 그 경우도 기다립니다.
      Wait-ForScreen -Game $game -TimeoutSeconds 10 -Description '함께하기 화면(입장하기/이동하기 버튼)' -Condition {
        (Test-PartyDetailScreen -Game $game) -or ((Get-EnterButtonText -Game $game) -match '이동|동하')
      }
      # 사후 검증: 두 탭의 입장 버튼 영역이 겹쳐 위 대기가 혼자하기 화면에서도 통과될 수
      # 있으므로, 탭 선택 배경색(함께하기=보라)으로 실제 전환을 확인합니다
      Confirm-TabSelected -Game $game -Point $ptPartyTab -Label '함께하기' | Out-Null

      # 캐릭터가 멀리 있으면: 이동하기 클릭 → 자동 이동 → 도착하면 상세 화면이 다시 열림
      # (혼자하기 탭의 이동 처리와 동일한 패턴 - '반드시 한 번은 클릭' 포함)
      if (-not (Test-PartyDetailScreen -Game $game) -and ((Get-EnterButtonText -Game $game) -match '이동|동하')) {
        Write-RunLog '[어비스] 5. 이동하기 클릭 - 던전까지 자동 이동'
        $moveDeadline = (Get-Date).AddSeconds(30)
        $moveClicked = $false
        $goneCount = 0
        while ((Get-Date) -lt $moveDeadline) {
          if ((Get-EnterButtonText -Game $game) -match '이동|동하') {
            $goneCount = 0
            Focus-Game -Game $game
            Click-GamePoint -Game $game -ReferenceX $ptEnter[0] -ReferenceY $ptEnter[1]
            $moveClicked = $true
            Start-Sleep -Milliseconds 1500
          } else {
            $goneCount++
            if ($goneCount -ge 2 -and $moveClicked) { break }
            Start-Sleep -Milliseconds 500
          }
        }
        if (-not $moveClicked) {
          Write-RunLog '[경고] 이동하기 버튼을 클릭하지 못했습니다 - 화면 상태를 확인해 주세요'
        }
        # 도착하면 상세 화면이 다시 열립니다 (열리는 탭 상태가 다를 수 있어 어느 쪽 버튼이든 인정)
        Wait-ForScreen -Game $game -TimeoutSeconds $timeoutTravel -Description '던전 도착(상세 화면)' -Condition {
          (Test-PartyDetailScreen -Game $game) -or (Test-DetailScreen -Game $game)
        }
        Write-RunLog '[어비스] 5. 던전 도착 - 상세 화면 다시 열림'
        Focus-Game -Game $game
        Click-GamePoint -Game $game -ReferenceX $ptPartyTab[0] -ReferenceY $ptPartyTab[1]
        Write-RunLog '[어비스] 3. 함께하기 탭 클릭 (도착 후 재확정)'
        Start-Sleep -Milliseconds 800
        Wait-ForScreen -Game $game -TimeoutSeconds 10 -Description '함께하기 화면(입장하기 버튼)' -Condition {
          Test-PartyDetailScreen -Game $game
        }
        Confirm-TabSelected -Game $game -Point $ptPartyTab -Label '함께하기' | Out-Null
      }

      # 난이도 확정 (함께하기는 지옥 난이도까지 같은 알약 줄에서 OCR로 찾아 클릭)
      & $selectDungeonDifficulty

      # 하단 버튼은 토글 상태에 따라 달라집니다 (실측):
      #   토글 켜짐 = 넓은 단일 '입장하기' / 꺼짐 = '파티 찾기' + '입장하기' 2버튼.
      # 그래서 매칭 방식에 맞게 토글부터 확정한 뒤 해당 버튼을 클릭합니다.
      if ($abyssMatching -eq '파티(파티장)') {
        # 파티장: 직접 짠 파티 그대로 입장합니다 (빈자리를 매칭으로 채우지 않음 - 사용자 결정).
        # 파티가 가득 차면(4/4) '우연한 만남' 토글이 비활성화되지만(실측), 인원이 부족한
        # 상태에서 토글이 켜져 있으면 모르는 사람이 채워지므로 꺼짐을 확정하고 입장합니다.
        $toggleState = Get-ChanceToggleState -Game $game -Point $ptAbyssChanceToggle
        if ($toggleState -eq 'on') {
          Focus-Game -Game $game
          Click-GamePoint -Game $game -ReferenceX $ptAbyssChanceToggle[0] -ReferenceY $ptAbyssChanceToggle[1]
          Start-Sleep -Milliseconds 900
          if ((Get-ChanceToggleState -Game $game -Point $ptAbyssChanceToggle) -eq 'on') {
            Write-RunLog "[경고] '우연한 만남' 토글을 끄지 못했습니다 - 빈자리가 매칭으로 채워질 수 있습니다"
          } else {
            Write-RunLog "[어비스] 5. '우연한 만남' 토글 끔 - 짠 파티 그대로 입장합니다"
          }
        } elseif ($toggleState -eq 'off') {
          Write-RunLog "[어비스] 5. '우연한 만남' 토글 꺼짐 확인 - 짠 파티 그대로 입장합니다"
        } else {
          Write-RunLog "[경고] '우연한 만남' 토글 상태를 판별하지 못했습니다(화면 확인 불가) - 클릭 없이 진행합니다"
        }

        # 입장하기 클릭. 접수되면 상세 화면이 닫히고 파티 패널의 버튼이 '입장 취소'로
        # 바뀝니다 (실측). '입장 취소'에도 '입장' 글자가 있어 그 자리를 다시 누르면 준비
        # 요청이 취소되므로(17:00 로그 실측 사고), '취소'가 보이면 성공으로 판정하고
        # 재클릭은 버튼이 여전히 '입장하기'로 남아 있을 때(클릭 빗나감)만 합니다.
        # 인원이 부족한 채 토글 없이 입장하면 '권장 인원보다 적은 인원으로 도전합니다'
        # 확인 팝업이 뜨는데(실측), 확인(도전하기)이 Space 조작이라 Space 로 넘깁니다.
        Focus-Game -Game $game
        Click-GamePoint -Game $game -ReferenceX $ptPartyEnter[0] -ReferenceY $ptPartyEnter[1]
        Write-RunLog '[어비스] 6. 입장하기 클릭 (파티장) - 파티원 준비 대기'
        $enterConfirmed = $false
        $enterDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $enterDeadline) {
          Start-Sleep -Seconds 3
          if (Test-InDungeonQuest -Game $game) { $enterConfirmed = $true; break }
          $challengeText = (Get-GameOcrText -Game $game) -replace '\s', ''
          if ($challengeText -match '도전하') {
            Focus-Game -Game $game
            Press-KeyOnce -VirtualKey ([byte]32)   # Space = 도전하기 확인
            Write-RunLog '[어비스] 인원 부족 도전 확인 팝업 - Space로 도전하기'
            continue
          }
          $partyBtnText = (Get-GameRegionOcrText -Game $game -ReferenceX $rgPartyEnterBtn[0] -ReferenceY $rgPartyEnterBtn[1] `
            -RegionWidth $rgPartyEnterBtn[2] -RegionHeight $rgPartyEnterBtn[3] -Scale 4 -Engine $ocrKoreanEngine) -replace '\s', ''
          if ($partyBtnText -match '취소') {
            Write-RunLog "[어비스] 준비 대기 시작 확인 (버튼: 입장 취소)"
            $enterConfirmed = $true
            break
          }
          if ($partyBtnText -match '입장하기|장하기') {
            Write-RunLog '[어비스] 입장하기가 눌리지 않은 것 같아 다시 클릭합니다'
            Focus-Game -Game $game
            Click-GamePoint -Game $game -ReferenceX $ptPartyEnter[0] -ReferenceY $ptPartyEnter[1]
          }
        }
        if (-not $enterConfirmed) {
          Write-RunLog "[경고] '입장 취소' 버튼(준비 대기 시작)을 확인하지 못했습니다 - 그대로 입장 대기를 진행합니다"
        }
      } elseif ($abyssMatching -eq '우연한 만남') {
        # '우연한 만남' 토글 확인 - 꺼져 있으면 켭니다 (초록 = 켜짐, 픽셀 판별)
        $toggleState = Get-ChanceToggleState -Game $game -Point $ptAbyssChanceToggle
        if ($toggleState -eq 'unknown') {
          Write-RunLog "[경고] '우연한 만남' 토글 상태를 판별하지 못했습니다(화면 확인 불가) - 클릭 없이 현재 상태로 진행합니다"
        } elseif ($toggleState -ne 'on') {
          Focus-Game -Game $game
          Click-GamePoint -Game $game -ReferenceX $ptAbyssChanceToggle[0] -ReferenceY $ptAbyssChanceToggle[1]
          Start-Sleep -Milliseconds 900
          if ((Get-ChanceToggleState -Game $game -Point $ptAbyssChanceToggle) -eq 'on') {
            Write-RunLog "[어비스] 5. '우연한 만남' 토글 켬"
          } else {
            Write-RunLog "[경고] '우연한 만남' 토글이 켜진 것을 확인하지 못했습니다 - 현재 상태로 진행합니다"
          }
        } else {
          Write-RunLog "[어비스] 5. '우연한 만남' 토글 켜짐 확인"
        }

        # 입장하기 클릭 → 상세 화면이 닫히고 필드에서 매칭 대기가 시작됩니다
        Write-RunLog '[어비스] 6. 입장하기 클릭 - 파티원 대기 (모이면 자동 입장)'
        Invoke-ClickUntil -Game $game -Point $ptPartyEnter -Description '입장하기 클릭 확인(상세 화면 종료)' `
          -TimeoutSeconds 30 -Condition { -not (Test-PartyDetailScreen -Game $game) }
      } else {
        # 파티찾기: 토글이 켜져 있으면 '파티 찾기' 버튼이 없고 그 자리가 넓은 입장하기라
        # 잘못 누르면 우연한 만남으로 입장돼 버립니다. 반드시 토글을 먼저 끕니다.
        $toggleState = Get-ChanceToggleState -Game $game -Point $ptAbyssChanceToggle
        if ($toggleState -eq 'on') {
          Focus-Game -Game $game
          Click-GamePoint -Game $game -ReferenceX $ptAbyssChanceToggle[0] -ReferenceY $ptAbyssChanceToggle[1]
          Start-Sleep -Milliseconds 900
          if ((Get-ChanceToggleState -Game $game -Point $ptAbyssChanceToggle) -eq 'on') {
            throw "'우연한 만남' 토글을 끄지 못해 파티찾기를 진행할 수 없습니다 (토글이 켜진 상태에서는 파티 찾기 버튼이 없음)"
          }
          Write-RunLog "[어비스] 5. '우연한 만남' 토글 끔 (파티찾기 준비)"
        } elseif ($toggleState -eq 'unknown') {
          Write-RunLog "[경고] '우연한 만남' 토글 상태를 판별하지 못했습니다(화면 확인 불가) - 꺼짐으로 보고 진행합니다"
        } else {
          Write-RunLog "[어비스] 5. '우연한 만남' 토글 꺼짐 확인 (파티찾기 준비)"
        }

        # 파티 찾기 클릭 → 상세 화면이 닫히고 필드 좌상단에 '파티 찾는 중' 타이머가 뜹니다
        Write-RunLog '[어비스] 6. 파티 찾기 클릭 - 매칭 대기'
        Invoke-ClickUntil -Game $game -Point $ptPartyFind -Description '파티 찾기 클릭 확인(상세 화면 종료)' `
          -TimeoutSeconds 30 -Condition { -not (Test-PartyDetailScreen -Game $game) }
      }

      # 매칭 완료 → 자동 입장 감지: 매칭 중에는 캐릭터가 필드에 있어 HUD로는 구분이
      # 안 되므로, 던전 안에서만 퀘스트 추적기에 뜨는 '<던전 이름> 클리어' 목표로 판정합니다.
      if ($abyssMatching -eq '파티(파티장)') {
        Write-RunLog '[어비스] 7. 파티원 준비 대기 중... (전원 준비되면 자동 입장)'
      } else {
        Write-RunLog '[어비스] 7. 파티 매칭 대기 중... (끝나면 자동 입장)'
      }
      Wait-ForScreen -Game $game -TimeoutSeconds $timeoutPartyMatch -Description '파티 매칭 완료 후 던전 입장' -Condition {
        Test-InDungeonQuest -Game $game
      }
      Write-RunLog '[어비스] 8. 던전 입장 완료 감지'
    } else {
    Click-GamePoint -Game $game -ReferenceX $ptSoloTab[0] -ReferenceY $ptSoloTab[1]
    Write-RunLog '[어비스] 3. 혼자하기 탭 클릭'
    # 혼자하기 화면의 하단 버튼(입장하기 또는 이동하기)이 나타난 것을 확인합니다
    # (함께하기 탭에서 전환된 경우 화면이 바뀌는 시간을 안전하게 기다림)
    # OCR이 '이'를 'OI'처럼 깨뜨려도('OI동하기' 실측) 살아남는 '장하'/'동하'까지 함께 봅니다.
    Wait-ForScreen -Game $game -TimeoutSeconds 10 -Description '혼자하기 화면(입장하기/이동하기 버튼)' -Condition {
      (Get-EnterButtonText -Game $game) -match '입장|이동|장하|동하'
    }
    # 사후 검증: 탭 선택 배경색(혼자하기=청록)으로 실제 전환 확인 (빗나감 시 1회 재클릭)
    Confirm-TabSelected -Game $game -Point $ptSoloTab -Label '혼자하기' | Out-Null

    # 난이도 확정 (위에서 정의한 공용 동작)
    & $selectDungeonDifficulty

    # 캐릭터가 던전에서 먼 필드에 있으면 버튼이 '입장하기' 대신 '이동하기'로 표시됩니다.
    # 이동하기를 누르면 캐릭터가 던전까지 자동 이동하고, 도착하면 상세 화면이 다시 열리며
    # '입장하기'로 바뀝니다. 그때 혼자하기 탭/난이도를 다시 확정한 뒤 입장 단계로 갑니다.
    if ((Get-EnterButtonText -Game $game) -match '이동|동하') {
      Write-RunLog '[어비스] 5. 이동하기 클릭 - 던전까지 자동 이동'
      # 버튼 글자가 '이동'으로 보이는 동안 계속 클릭하고, 두 번 연속 안 보여야 넘어갑니다.
      # (OCR이 한 번 삐끗하면 클릭 없이 넘어가던 문제 수정 - 반드시 한 번은 클릭)
      $moveDeadline = (Get-Date).AddSeconds(30)
      $moveClicked = $false
      $goneCount = 0
      while ((Get-Date) -lt $moveDeadline) {
        if ((Get-EnterButtonText -Game $game) -match '이동|동하') {
          $goneCount = 0
          Focus-Game -Game $game
          Click-GamePoint -Game $game -ReferenceX $ptEnter[0] -ReferenceY $ptEnter[1]
          $moveClicked = $true
          Start-Sleep -Milliseconds 1500
        } else {
          $goneCount++
          if ($goneCount -ge 2 -and $moveClicked) { break }
          Start-Sleep -Milliseconds 500
        }
      }
      if (-not $moveClicked) {
        Write-RunLog '[경고] 이동하기 버튼을 클릭하지 못했습니다 - 화면 상태를 확인해 주세요'
      }
      Wait-ForScreen -Game $game -TimeoutSeconds $timeoutTravel -Description '던전 도착(상세 화면의 입장하기 버튼)' -Condition {
        Test-DetailScreen -Game $game
      }
      Write-RunLog '[어비스] 5. 던전 도착 - 상세 화면 다시 열림'
      Focus-Game -Game $game
      Click-GamePoint -Game $game -ReferenceX $ptSoloTab[0] -ReferenceY $ptSoloTab[1]
      Write-RunLog '[어비스] 3. 혼자하기 탭 클릭 (도착 후 재확정)'
      Start-Sleep -Milliseconds 800
      Confirm-TabSelected -Game $game -Point $ptSoloTab -Label '혼자하기' | Out-Null
      # 도착 후 상세 화면이 새로 열렸으니 난이도도 다시 확정합니다
      & $selectDungeonDifficulty
    }

    Write-RunLog '[어비스] 6. 입장하기 클릭'
    # 클릭하는 순간 사용자가 마우스를 움직이면 클릭이 빗나갈 수 있습니다(커서 이동 후
    # 클릭 사이의 짧은 틈에 커서가 옮겨지면 그 자리를 클릭하게 됨). 그래서 상세 화면이
    # 사라진 것(=입장이 접수되어 로딩 시작)이 확인될 때까지 5초마다 다시 클릭합니다.
    Invoke-ClickUntil -Game $game -Point $ptEnter -Description '입장하기 클릭 확인(상세 화면 종료)' `
      -TimeoutSeconds 30 -Condition { -not (Test-DetailScreen -Game $game) }
    Write-RunLog '[어비스] 7. 던전 로딩 중...'
    Start-Sleep -Seconds 1
    Wait-ForScreen -Game $game -TimeoutSeconds $timeoutEntry -Description '던전 입장 완료 화면' -Condition {
      Test-DungeonEntered -Game $game
    }
    Write-RunLog '[어비스] 8. 던전 입장 완료 감지'
    }
  }

  # 입장 직후 키 입력 (config afterEntry.keys 중 enabled 만 - 공통 헬퍼)
  Invoke-AfterEntryKeys -Game $game -LogPrefix '[어비스]'

  Write-RunLog '[어비스] 10. 클리어 화면 감지 대기 시작'
  $clearOutcome = Wait-ForDungeonClearScreen -Game $game -TimeoutSeconds $timeoutClear

  # 사용자가 직접 화면을 넘긴 경우(reward/selection)에는 해당 단계를 건너뛰고 이어갑니다.
  if ($clearOutcome -eq 'clear') {
    Write-RunLog '[어비스] 11. 클리어 화면 터치'
    # 등급 연출 중에는 터치가 무시될 수 있어(다른 PC 실측: 터치 후에도 '화면을 터치'가
    # 그대로 남음) 나가기 버튼이 보일 때까지 3초 간격으로 다시 터치합니다.
    Invoke-ClickUntil -Game $game -Point $ptClearCenter -Description '클리어 화면 터치(나가기 버튼 표시)' `
      -TimeoutSeconds ($timeoutExit + 15) -ReclickEverySeconds 3 -Condition { Test-ExitButton -Game $game }
    Write-RunLog '[어비스] 12. 나가기 버튼 감지'
  }
  if ($clearOutcome -ne 'selection') {
    Focus-Game -Game $game
    Click-GamePoint -Game $game -ReferenceX $ptExitButton[0] -ReferenceY $ptExitButton[1]
    Write-RunLog '[어비스] 13. 나가기 클릭'
  }
  Return-ToAbyssSelection -Game $game
  Write-RunLog '[완료] 어비스 선택 화면 복귀 완료'
} catch {
  Write-RunLog "[오류] $($_.Exception.Message)"

  # ===== 오류 진단 덤프 =====
  # 실패 원인을 파악할 수 있도록 게임 창 스크린샷과 주요 OCR 원문을 Log 폴더에 남깁니다.
  # 스크린샷과 로그 사본은 같은 타임스탬프로 세트가 됩니다 (error_시각.png + error_시각.log).
  # 시각은 읽기 쉽게 h/m/s 표기를 씁니다 (예: error_20260718_h21m49s09.png).
  $diagStamp = Get-Date -Format 'yyyyMMdd_\hHH\mmm\sss'
  try {
    if ($game) {
      $diagRect = New-Object HoneyNogiInput+RECT
      if ([HoneyNogiInput]::GetWindowRect($game.MainWindowHandle, [ref]$diagRect)) {
        $diagW = $diagRect.Right - $diagRect.Left
        $diagH = $diagRect.Bottom - $diagRect.Top
        Write-RunLog "[진단] 게임 창: ${diagW}x${diagH} @ L$($diagRect.Left),T$($diagRect.Top)"

        $diagShot = Join-Path $logDir ("error_{0}.png" -f $diagStamp)
        $diagBmp = New-Object System.Drawing.Bitmap $diagW, $diagH
        $diagGfx = [System.Drawing.Graphics]::FromImage($diagBmp)
        try {
          $diagGfx.CopyFromScreen($diagRect.Left, $diagRect.Top, 0, 0, $diagBmp.Size)
          $diagBmp.Save($diagShot, [System.Drawing.Imaging.ImageFormat]::Png)
          Write-RunLog "[진단] 화면 캡처 저장: $diagShot"
        } finally {
          $diagGfx.Dispose()
          $diagBmp.Dispose()
        }

        # 오래된 진단 스크린샷 정리: 최근 것만 남기고(기본 10개) 나머지는 삭제해
        # Log 폴더에 무한정 쌓이지 않게 합니다. config 의 diagnostics.keepScreenshots 로 조절.
        $keepShots = [int](Get-ConfigValue $config @('diagnostics', 'keepScreenshots') 10)
        if ($keepShots -gt 0) {
          $oldShots = @(Get-ChildItem -LiteralPath $logDir -Filter 'error_*.png' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $keepShots)
          foreach ($old in $oldShots) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
          }
          if ($oldShots.Count -gt 0) {
            Write-RunLog "[진단] 오래된 진단 스크린샷 $($oldShots.Count)개 정리(최근 ${keepShots}개 유지)"
          }
        }

        $diagDetail = Get-GameRegionOcrText -Game $game -ReferenceX $rgEnterButton[0] -ReferenceY $rgEnterButton[1] `
          -RegionWidth $rgEnterButton[2] -RegionHeight $rgEnterButton[3] -Scale 3 -Engine $ocrKoreanEngine
        Write-RunLog "[진단] 입장하기 영역 OCR: '$diagDetail'"
        $diagHud = Get-GameRegionOcrText -Game $game -ReferenceX $rgHomeEndEsc[0] -ReferenceY $rgHomeEndEsc[1] `
          -RegionWidth $rgHomeEndEsc[2] -RegionHeight $rgHomeEndEsc[3] -Scale 5 -Engine $ocrEnglishEngine -BinaryWhiteText
        Write-RunLog "[진단] HUD 영역 OCR: '$diagHud'"
        $diagBottom = Get-GameOcrText -Game $game
        Write-RunLog "[진단] 하단 문구 영역 OCR: '$diagBottom'"
      }
    }
  } catch {
    Write-RunLog "[진단] 진단 수집 실패: $($_.Exception.Message)"
  }

  # ===== 오류 로그 사본 보관 =====
  # 현재 로그 파일은 다음 회차가 시작되면 지워지므로, 오류 순간의 로그 전문을
  # 스크린샷과 같은 이름(error_시각.log)으로 복사해 세트로 남깁니다.
  # 위의 [오류]/[진단] 줄까지 모두 기록된 뒤에 복사하도록 맨 마지막에 수행합니다.
  try {
    $diagLog = Join-Path $logDir ("error_{0}.log" -f $diagStamp)
    Copy-Item -LiteralPath $logPath -Destination $diagLog -Force
    # 좌표 버전 게이트 상태는 사용자 로그(GUI 표시)에는 보이지 않게, 오류 사본에만 직접 기록합니다
    if ($script:staleCoordsIgnored) {
      Add-Content -LiteralPath $diagLog -Encoding UTF8 -ErrorAction SilentlyContinue `
        -Value '[분석용] config 좌표가 구버전(coordsVersion 미달)이라 내장 최신 좌표로 동작 중이었음'
    }
    Write-RunLog "[진단] 오류 로그 사본 저장: $diagLog"
    # 로그 사본도 스크린샷과 같은 보관 규칙(기본 10개)으로 정리합니다
    $keepLogs = [int](Get-ConfigValue $config @('diagnostics', 'keepScreenshots') 10)
    if ($keepLogs -gt 0) {
      $oldLogs = @(Get-ChildItem -LiteralPath $logDir -Filter 'error_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $keepLogs)
      foreach ($old in $oldLogs) {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {
    Write-RunLog "[진단] 오류 로그 사본 저장 실패: $($_.Exception.Message)"
  }
  exit 1
}





