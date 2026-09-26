[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [한국어](README.ko.md) | [Español](README.es.md)

# kilde

[![Release](https://github.com/kilde-team/kilde/actions/workflows/release.yml/badge.svg)](https://github.com/kilde-team/kilde/actions/workflows/release.yml)

macOS용 오픈 소스 화면·오디오 녹화 도구.

kilde는 화면과 **QuickTime Player의 화면 녹화로는 잡을 수 없는 시스템 사운드**를
함께 녹화합니다 — 단일 명령 CLI와 메뉴 막대 앱 두 가지 방식으로.

이 프로젝트는 두 개의 저장소로 나뉩니다 (issue #115):

| 저장소 | 내용 | 공개 범위 |
|---|---|---|
| [kilde-team/kilde](https://github.com/kilde-team/kilde) (이 저장소) | 메뉴 막대 앱 (`gui/`), 릴리스 서명·배포, Homebrew formula, 문서 | 공개 |
| [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift) | 녹화 엔진 (`KildeCore`)과 `kilde` CLI 소스 | 비공개 (kilde-team 멤버) |

## 주요 기능

- **녹음 동의는 사용자의 책임입니다**: 회의를 녹음할 때는 거주 지역의 법령을 준수하고 참가자에게 녹음을 알리고 동의를 받으세요.

- 🖥️ 네이티브 ScreenCaptureKit으로 추가 설정 없이 화면 + 시스템 사운드 녹화
- 🎤 마이크 또는 BlackHole 같은 입력 기기를 동시 녹음
  - 여러 소스를 기본적으로 **한 트랙에 믹스**, `--audio-tracks separate`로
    트랙 분리도 가능
- 🪟 **창 단위 캡처** — 시스템 사운드도 해당 앱으로 범위가 한정되어 알림음 등
    다른 앱의 소리가 들어가지 않음
- 🎙️ `--no-video`로 오디오만 녹음 — 추가 드라이버 불필요
- 🛡️ Ctrl+C로 중단해도 파일이 반드시 안전하게 파이널라이즈됨
- ⌨️ 전역 단축키로 다른 앱을 쓰면서도 녹화 시작/중지
- ⚡️ 단축어 앱에서 녹화 조작 — 시작(화면/창 또는 오디오만), 중지, 최신 전사 가져오기로 자동화 지원
- 📝 녹화물을 온디바이스에서 전사해 markdown / SRT / VTT / 텍스트 / JSON 사이드카
  파일로 출력 (macOS 26+)

## 설치

- macOS 14 이상
- 전사는 **macOS 26 이상**이 필요합니다
- 릴리스 바이너리는 **arm64 (Apple Silicon) 빌드**입니다 — 현재 Intel Mac은 미지원
- 실행 테스트는 현재 Apple Silicon의 macOS 26에서 수행
- 빌드에는 macOS 26 SDK를 포함한 툴체인이 필요합니다 (엔진이 macOS 26 API
  `captureHDRRecordingPreservedSDRHDR10`을 참조하기 때문. 실행은 계속 macOS 14+ 지원)

### Mac App Store

메뉴 막대 앱은 Mac App Store에서 제공됩니다 — 클릭 한 번으로 설치되고
App Store가 자동으로 업데이트합니다:

<a href="https://apps.apple.com/app/id6812783176">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/appstore/badge/mac-app-store-badge-ko-white.svg">
    <img src="docs/appstore/badge/mac-app-store-badge-ko-black.svg" alt="Mac App Store에서 다운로드" height="40">
  </picture>
</a>

### Homebrew

```sh
brew tap kilde-team/kilde
brew trust --formula kilde-team/kilde/kilde   # 최초 1회 (새 Homebrew에서만 필요)
brew install kilde

# tap에서 바로 설치
brew install kilde-team/kilde/kilde
```

### 릴리스 바이너리

[GitHub Releases](https://github.com/kilde-team/kilde/releases)에서
`kilde-<버전>-macos.zip`을 받아 압축을 풀고 `kilde` 바이너리를 `PATH`가
통과하는 곳에 두세요:

```sh
unzip kilde-*-macos.zip && sudo cp release/kilde /usr/local/bin/
```

### 소스에서 빌드

`kilde` CLI와 `KildeCore` 엔진은
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
(**비공개**)에서 개발되므로 현재 공개 소스 빌드는 제공되지 않습니다 —
Homebrew 또는 릴리스 바이너리를 이용해 주세요. kilde-team 멤버는 해당
저장소를 clone해 `swift build`로 빌드할 수 있습니다 (절차는 그 저장소의
문서 참조).

## 시작하기

`doctor`부터 실행하세요. 화면 녹화와 마이크 캡처에는 macOS 권한이 필요하며,
이 명령은 환경을 점검하고 아직 승인하지 않은 권한을 요청합니다:

```sh
kilde doctor
```

그다음 화면과 시스템 사운드를 녹화합니다. Ctrl+C로 중지하면 파일을 안전하게
파이널라이즈합니다:

```sh
kilde rec demo.mov
```

다른 명령들로 캡처 대상을 찾고, 녹화 파일을 검사하고, 녹화 기본값을 관리할 수
있습니다:

```sh
kilde devices         # 디스플레이, 창, 오디오 기기 목록
kilde inspect FILE    # 녹화 파일의 트랙 구성과 오디오 레벨 표시
kilde transcribe FILE # 녹화 파일을 전사해 사이드카 파일로 출력 (macOS 26+)
kilde config show     # 설정된 값과 적용 중인 기본값 표시
```

## 녹화 예시

화면 전체(기본) 또는 일부를 녹화합니다. `--region`은 왼쪽 위가 원점인
`x,y,w,h`(포인트)를 받습니다. 너비·높이는 H.264 제약으로 짝수로 내림됩니다.
디스플레이 범위를 벗어나면 녹화 시작 전에 실패하고 (종료 코드 1), 형식이
틀리거나 2포인트 미만인 값은 인자 오류입니다 (종료 코드 64). `--window`,
`--no-video`, `--preset meeting`과는 함께 쓸 수 없습니다:

```sh
# 화면 전체 + 시스템 사운드 (기본)
kilde rec demo.mov

# 화면의 일부
kilde rec --region 0,0,1280,720 demo.mov
```

Zoom, Google Meet, Teams 회의를 녹화합니다. meeting 프리셋은 창을
선택하게 한 뒤, 상대방의 시스템 사운드와 내 마이크를 한 트랙에 믹스합니다:

```sh
kilde rec --preset meeting meeting.mov
```

마이크를 명시적으로 추가하거나, 오디오만 M4A로 녹음하거나, 캡처를 특정 앱
창으로 한정할 수도 있습니다. `--window`는 부분 제목, bundle ID, 창 ID로
매칭합니다. 사용 가능한 창은 `kilde devices`로 확인하세요.

```sh
# 화면 + 시스템 사운드 + 마이크
kilde rec --audio system --audio mic out.mov

# 오디오만
kilde rec --no-video memo.m4a

# 매칭되는 Zoom 창의 소리만, 다른 앱 제외
kilde rec --no-video --window zoom meeting.m4a

# 여러 창을 한 파일에. --window는 여러 번 지정할 수 있으며 출력은 디스플레이
# 전체 크기이고 그 밖의 영역은 검정으로 채워집니다
kilde rec --window zoom --window notes demo.mov

# 전체 화면 녹화에서 특정 앱을 숨깁니다. 예: 암호 관리자, 채팅 클라이언트.
# bundle ID는 정확히 일치해야 합니다 -- `kilde devices`로 확인하세요
#   주의: 제외된 앱의 *소리*도 함께 사라집니다. 회의 앱이나 브라우저를
#   제외하면 그 소리도 잃으므로, 화면만 가리고 싶다면 --window로 원하는
#   창만 녹화하는 쪽을 권합니다
kilde rec --exclude-app com.1password.1password --exclude-app com.tinyspeck.slackmacgap demo.mov

# HDR 캡처. macOS 15 이상, HDR 디스플레이, HEVC가 필요합니다.
# 출력은 HEVC Main10 (PQ)이며 색역은 OS 프리셋을 따릅니다
#   (macOS 26: HDR10 메타데이터가 붙은 BT.2020, 15: Display P3)
#   하나라도 갖춰지지 않으면 kilde는 SDR로 녹화, 이유를 알리고 여전히 종료 코드 0으로
#   끝납니다 -- HDR이 아니면서 HDR이라고 믿게 될 파일은 건네주지 않습니다
kilde rec --hdr --codec hevc demo.mov
```

BlackHole을 거쳐 녹음하면서 동시에 소리를 듣고 싶다면 BlackHole을 설치하고
monitor 모드를 사용하세요. monitor 모드는 녹화 세션 동안 필요한 멀티
출력 기기를 임시로 만들고 해제합니다.

```sh
brew install --cask blackhole-2ch
kilde rec --no-video --audio "device:BlackHole 2ch" --monitor meeting.m4a
```

kilde를 단축키 대기 모드로 실행하고 전역 Cmd+Shift+R로 녹화를 시작/중지할 수
있습니다. 대기 중의 Ctrl+C는 파일을 만들지 않고 종료합니다. `--hotkey`는
`--countdown`과 함께 쓸 수 없습니다.

```sh
kilde rec --hotkey cmd+shift+r meeting.mov
```

`--duration`은 단축키와 *함께 쓸 수 있지만*, 실행 시점이 아니라 **대기가
끝난 시점**부터 셉니다. 따라서 설정 파일에 `hotkey`가 있으면
`kilde rec --duration 30s`조차 대기에 들어가고, 무인 스크립트는 누군가
키를 누를 때까지 멈춰 있는 셈이 됩니다 (Ctrl+C, SIGTERM, SIGHUP 모두
깔끔하게 종료). *설정에서 온* 단축키가 요청한 `--duration`을 미루게 되면
kilde는 stderr에 경고를 출력합니다. 명시적인 `--hotkey`는 대기가 요청한
동작이므로 조용히 유지됩니다. 무인으로 녹화하려면
`kilde config unset hotkey`로 설정의 단축키를 제거하세요.

### 녹화 후 전사

`--transcribe`를 붙이면 녹화 파일이 완성되는 즉시 사이드카 파일(`meeting.md`)로
전사합니다 (macOS 26+, Speech recognition 권한 불필요):

```sh
kilde rec --transcribe --preset meeting meeting.mov
```

전사는 전부 내 Mac에서(온디바이스) 실행됩니다 — 오디오도 전사 텍스트도 어디로도
전송되지 않습니다. 전사는 녹화 파일이 완성된 *후에만* 시작되므로 실패나 중단이
녹화 자체에 영향을 주지 않습니다. 전사 중의 Ctrl+C는 전사만 중단합니다 — 녹화
파일은 디스크에 남고 종료 코드는 여전히 `0`입니다. 전사 *실패*(지원되지 않는
환경이나 언어, 모델 다운로드 실패 등)는 `1`로 종료합니다 — 명시적으로 요청했기
때문입니다. `--transcript-format md|srt|vtt|txt|json`으로 사이드카 형식을,
`--locale ja-JP`로 언어를 지정합니다. `--no-video --audio-tracks separate`
녹화에서는 두 오디오 트랙이 화자 레이블과 함께 전사됩니다 (시스템 사운드 트랙 =
"相手", 마이크 트랙 = "自分"). 기존 녹화 파일은 `kilde transcribe FILE`로 전사할
수도 있습니다.

### BlackHole이 필수가 아닌 이유는?

kilde는 ScreenCaptureKit의 네이티브 시스템 사운드 캡처를 사용하므로,
평범한 화면·오디오 녹화에는 가상 오디오 드라이버가 필요 없습니다.
BlackHole이 필요한 것은 monitor 모드처럼 녹음하면서 같은 소리를 듣고
싶은 등 특수한 라우팅뿐입니다.

## 녹화 옵션과 기본값

기본적으로 kilde는 0번 디스플레이를 캡처하고, `system` 사운드를 `mixed`
오디오 트랙으로 녹음하며, 비디오 코덱은 H.264, 커서를 포함합니다. 출력
경로가 없으면 `kilde-yyyyMMdd-HHmmss.mp4`를 만듭니다 (`--format mov`를
선택하거나 ProRes가 기본 컨테이너를 `mov`로 되돌릴 때는 `.mov`, 오디오 전용
모드에서는 `.m4a`). 전체 옵션 목록은 `kilde rec --help`를 실행하세요.

자주 쓰는 옵션:

- `--display NUMBER` 또는 `--window MATCH`로 캡처 대상 선택
- 반복 가능한 `--audio system|mic|device:NAME_OR_UID|none`으로 오디오 소스 선택
- `--audio-tracks mixed|separate`로 소스를 믹스하거나 트랙 분리
- `--no-video`, `--monitor`, `--duration 30s` (단축키 대기 종료 시점부터 계산,
  실행 시점이 아님), `--codec h264|hevc|prores`, `--fps NUMBER`,
  `--format mov|mp4` (출력 경로의 `.mov`/`.mp4` 확장자도 컨테이너를 결정합니다.
  ProRes는 MP4에 담을 수 없으므로 단독 `--codec prores`는 `mov`로 폴백)
- `--cursor` 또는 `--no-cursor`, `--countdown SECONDS`, `--preset meeting`,
  `--hotkey SHORTCUT`
- `--transcribe` (`--transcript-format` 및 `--locale`과 함께): 녹화 파일이
  완성된 후 사이드카 파일로 전사 (macOS 26+)
- `-o PATH` 또는 `--output PATH`: 위치 인자 출력 경로의 대안

## 설정

`rec`의 영구 기본값은 `~/.kilde/config.json`에 저장됩니다. 파일을 손으로
고르지 말고 `kilde config show|set|unset|path`로 관리하세요.

```sh
kilde config set outputDirectory ~/Movies/kilde
kilde config set defaultAudioSources system,mic
kilde config set showsCursor false   # 이번 한 번만 커서를 보이려면 kilde rec --cursor
kilde config set hotkey cmd+shift+r  # rec를 단축키 대기 모드로 시작 (아래 상호배제 참조)
kilde config set transcribe true     # 정지할 때마다 전사
kilde config set transcriptFormat srt
kilde config set locale ja-JP
kilde config show
kilde config unset hotkey
kilde config path
```

지원하는 키는 `outputDirectory`, `defaultAudioSources`, `audioTracks`,
`codec`, `format`, `videoBitrate`, `audioBitrate`, `fps`, `showsCursor`,
`hotkey`, `transcribe`, `transcriptFormat`, `locale`입니다.

녹화 설정은 다음 순서(높음→낮음)로 해석됩니다:

1. CLI 인자
2. `--preset`
3. `KILDE_OUTPUT_DIR` 같은 환경 변수
4. 설정 파일
5. 내장 기본값

단축키에는 이에 대응하는 별도 순서가 있습니다: `--hotkey` → 설정된
`hotkey` → 대기 모드 없음.

전역 단축키는 한 번에 한 프로세스만 가질 수 있으므로 **먼저 등록한 프로세스가
이깁니다**. 메뉴 막대 앱이 실행 중일 때 중요합니다 — 로그인 시 실행되어 설정된
단축키를 쥐고 있기 때문입니다. `rec`가 단축키가 이미 점유된 것을 발견하면,
설정 파일에서 온 단축키는 건너뜁니다: 경고를 출력하고 대기하지 않고 즉시
녹화를 시작합니다. 명시적인 `--hotkey`는 대기가 요청한 동작이므로 이유와 함께
실패합니다.

`rec`는 결정 직전에 단축키 사용 가능 여부를 확인하므로, 그 사이에 다른
프로세스가 키를 가로채면 여전히 등록 오류로 종료합니다 — 실제로는 두 녹화를
거의 동시에 시작해야 일어나며, GUI가 쥔 단축키는 이 검사에서 잡힙니다.

`KILDE_CONFIG_DIR`을 설정하면 `config.json`과 `monitor-state.json`의
저장 위치를 함께 옮길 수 있어 격리 환경과 테스트에 유용합니다. 값은 절대
경로 또는 `~`로 시작해야 하며 상대 경로는 거부됩니다. 잘못된 설정이나 없는
출력 디렉터리는 녹화 전에 실패하며 종료 코드는 `1`입니다.

## 종료 코드

| 코드 | 의미 |
|---:|---|
| `0` | 성공. SIGINT, SIGTERM, SIGHUP으로 안전하게 중지된 녹화 포함. `rec --transcribe`의 녹화 후 전사를 Ctrl+C로 중단해도 `0`으로 종료 — 녹화 파일은 디스크에 남습니다 |
| `1` | 기타 런타임 오류. 잘못된 설정 포함. `rec --transcribe`의 녹화 후 전사 실패(지원되지 않는 환경이나 언어, 모델 다운로드 실패, 사이드카 쓰기 실패)도 `1`로 종료 — 녹화 파일은 남지만 전사는 명시적으로 요청한 것이므로 |
| `2` | 권한 없음 |
| `3` | 디스플레이, 창 또는 오디오 기기를 찾을 수 없음 |
| `64` | 명령줄 파싱 또는 옵션 검증 오류. 예: `rec --fps 0` |

## GUI

`gui/`의 메뉴 막대 앱은 `NSStatusItem`과 `NSPopover`를 사용합니다. SwiftUI의
`MenuBarExtra`(`.window` 패널)가 macOS 26에서 열리지 않기 때문에 AppKit으로
수동 관리합니다. GUI는
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
(비공개 — 패키지 해석에는 kilde-team git 자격 증명 필요)에 대한 **revision
고정** 의존성으로 CLI와 동일한 `KildeCore` 녹화 엔진을 공유합니다. 커밋하지
않는 Xcode 프로젝트는 `project.yml`에서
[XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 생성합니다:

```sh
brew install xcodegen   # 최초 1회만
cd gui && xcodegen
open KildeGUI.xcodeproj # Xcode에서 KildeGUI 스킴 실행
```

빌드하면 메뉴 막대에 ● 아이콘이 나타납니다. 클릭해 캡처 대상(화면 / 창 /
오디오만), 오디오 소스, 출력 디렉터리를 고르고 녹화를 시작하세요. 녹화 중에는
메뉴 막대에 경과 시간이, 패널에는 소스별 레벨 미터가 표시됩니다. 패널을
닫아도 녹화는 계속됩니다. 초기값은 CLI와 동일한 `~/.kilde/config.json`에서
읽습니다.

녹화가 끝나면 알림이 파일 이름·길이·크기를 알려 줍니다. 알림을 클릭하면
Finder에서 해당 파일이 선택된 채로 열립니다. 패널에는 출력 디렉터리의 최근
녹화 5건이 표시됩니다 (**CLI로 만든 파일도 포함**) — 클릭하면 역시 Finder에서
열립니다. 패널에서 전역 단축키를 설정하면 어떤 앱에서든 녹화를 시작/중지할 수
있으며, 같은 설정 파일의 `hotkey`로 저장되므로 `kilde rec`도 이를
반영합니다. 체크박스는 `SMAppService`로 로그인 시 실행을 등록하며, macOS가
시스템 설정에서 승인을 요구할 수 있습니다.

설정 파일을 CLI와 공유하는 것은 직접 배포판(GitHub Releases / Homebrew, 또는
소스에서 빌드한 앱)뿐입니다. Mac App Store 버전은 App Sandbox에서 실행되므로
`~/.kilde`를 읽을 수 없고, 설정을 앱 컨테이너 안
(`~/Library/Containers/com.takezou621.KildeGUI/Data/Library/Application Support/kilde/`)에 저장합니다.
따라서 초기값, 전역 단축키 등의 설정은 `kilde rec`와 공유되지 않습니다.

## 개발

- 엔진과 CLI (`KildeCore`, `kilde`):
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
  (비공개)에서 개발 — 테스트와 CI도 해당 저장소가 담당
- 메뉴 막대 앱, 릴리스 workflow, Homebrew formula: 이 저장소
  - 빌드·권한·GUI 문제 해결:
    [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  - 정식 릴리스 (서명, notarization, 배포):
    [docs/RELEASE.md](docs/RELEASE.md)
- 아키텍처와 동작: [docs/DESIGN.md](docs/DESIGN.md)
- M0 스파이크 결과: [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- 수익화 전략 조사 (일본어):
  [docs/MONETIZATION.md](docs/MONETIZATION.md)

## 로드맵

- **M0** ✅ 기술 스파이크: ScreenCaptureKit 오디오 캡처 검증
- **M1** ✅ CLI MVP: `kilde rec / devices / doctor / audio monitor / inspect`
  (엔진과 CLI 소스는
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)로
  이전됨, issue #115)
- **M2** 전역 단축키 ✅; 영역 캡처 ✅; 일시정지/재개
- **M3** 메뉴 막대 GUI 앱: 골격 ✅ / 녹화 UI ✅ / 권한 온보딩 ✅ /
  완료 알림·최근 녹화·전역 단축키·로그인 시 실행 ✅

## 이름의 유래

*kilde*는 덴마크어·노르웨이어로 **「근원」**을 뜻하는 단어입니다. 본래
물이 땅에서 솟는 「샘」을 가리키며, 확장하여 기자나 학자가 말하는
「출처」(source)의 의미로도 쓰입니다.

요즘 지식의 상당수는 온라인 회의와 화면 속에서 만들어집니다. AI가 녹화물을
전사·요약·검색할 수 있는 시대에 녹화 — 영상, 소리, 화면 — 는 회의가
끝나면 버리는 부산물이 아니라 **그 자체로 가치 있는 정보원**입니다.
kilde라는 이름은 이 도구가 남겨야 할 것 = 근원에서 왔습니다. 같은
믿음에서, kilde는 녹화를 중지할 때 — Ctrl+C라도 — 반드시 파이널라이즈된
재생 가능한 파일을 남깁니다. 다시 열 수 없는 출처는 출처가 아니니까요.

## 기여

버그 보고, 기능 제안, pull request를 환영합니다. 시작은
[CONTRIBUTING.md](CONTRIBUTING.md)를 참조하세요. 녹화 엔진과 CLI의 개발은
kilde-team/kilde-cli-swift에서 이루어집니다.

## 라이선스

[MIT License](LICENSE)
