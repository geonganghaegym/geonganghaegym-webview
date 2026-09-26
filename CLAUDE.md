# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

"건강해짐"(geonganghaegym) 앱을 감싸는 얇은 Flutter WebView 래퍼. 실제 화면·로직은 전부
`https://geonganghaegym.junghaebom.com` 웹앱에 있고(`lib/main.dart`의 `kWebBaseUrl`. 출시된 iOS 1.0은
아직 옛 도메인 `geonganghaejim.site`를 연다), 이 레포는 다음만 담당한다:

- `flutter_inappwebview`로 그 URL을 전체 화면에 띄운다 (`lib/main.dart`).
- Firebase Cloud Messaging으로 푸시 알림을 받아 로컬 알림으로 표시한다.
- 웹 쪽 로그인 결과를 JS 브릿지로 받아 FCM 토큰을 백엔드에 등록한다.
- 안드로이드 뒤로가기 제스처를 웹뷰 히스토리와 앱 종료 확인으로 연결한다.

앱 코드는 사실상 `lib/main.dart` 하나뿐이다(`lib/firebase_options.dart`는 FlutterFire CLI 생성 파일).
라우팅, 상태관리, 별도 위젯 트리 없음 — 새 화면/기능은 원칙적으로 웹 쪽에서 구현하고,
네이티브 쪽 변경은 웹-네이티브 브릿지나 플랫폼 권한/푸시 관련일 때만 필요하다.

## 빌드 · 테스트 · 실행

이 레포에서 작업할 때는 `flutter-verify` 스킬의 절차를 따른다(분석/테스트/포맷/빌드/실기기 실행 전부 포함).
아래는 그 스킬과 별개로, 이 레포 고유의 예외 사항이다.

- **테스트 디렉터리 없음.** `test/`가 존재하지 않으므로 `flutter test`는 현재 대상이 없다.
  새 기능에 테스트가 필요하면 `test/` 디렉터리부터 만든다.
- **`flutter clean`을 함부로 돌리지 않는다.** iOS는 CocoaPods(`ios/Podfile`)로 관리되며,
  clean 이후 `pod install`이 꼬이면 빌드가 깨질 수 있다.
- **`.env` 파일은 커밋되지 않고(`--dart-define`으로도 주입되지 않음) 코드에서 참조되지 않는다.**
  `KAKAO_CLIENT_ID`/`NAVER_CLIENT_ID`/`GOOGLE_CLIENT_ID`/`APPLE_CLIENT_ID` 등이 들어 있지만
  현재 `lib/` 어디에서도 로드하지 않는 죽은 설정이다 — 소셜 로그인은 웹 쪽에서 처리된다.
  이 값들을 "빌드에 안 먹는다"고 오판하지 말 것; 애초에 안 쓰인다.
- 안드로이드 release 서명은 `android/key.properties`(gitignore)가 있을 때만 적용되고,
  없으면 debug 키로 서명한다 — `signingConfigs.release`가 통째로 없어도 정상이다.

## Play 스토어 배포

Play Console을 브라우저로 조작하는 대신 **Gradle Play Publisher(GPP) 3.13.0**으로 API 배포한다.
전체 배경·검증된 명령·트랙 승격·테스터 그룹 연결은 `docs/play-deploy.md`에 정리되어 있다 —
배포 관련 작업 전에 반드시 그 문서를 먼저 읽는다. 핵심만 요약:

- GPP는 `android/play-service-account.json`(gitignore, 서비스 계정 키)이 있어야 활성화된다.
  없으면 `play { enabled = ... }`가 자동으로 꺼진다(`android/app/build.gradle`).
- 대표 명령: `flutter build appbundle --release` → `cd android && ./gradlew publishBundle --console=plain`.
  트랙/상태는 `--track` `--release-status` `--user-fraction`으로 CLI에서 덮어쓴다.
- GPP 버전을 함부로 올리지 않는다 — **4.x는 AGP 9.0.0+ 요구, 현재 AGP는 8.13.2**라 3.13.0 고정.
  2026-09-27 AGP 9.4.0 + GPP 4.1.1로 실제 전환을 시도했으나, `flutter_inappwebview` 6.1.5가 물고 오는
  `flutter_inappwebview_android` 1.1.3(2026-09-27 기준 pub 최신)의 `android/build.gradle`이 AGP 9에서
  제거된 `getDefaultProguardFile('proguard-android.txt')`를 호출해 `assembleDebug` 단계에서 즉시
  실패했다 — 이게 첫 번째로 걸린 차단 요인이고, `kotlin-android` 플러그인과 AGP9 내장 Kotlin 간
  충돌 등 더 있을 수 있는 이슈는 이 지점 이후를 확인하지 못해 알 수 없다. AGP 9 전환은 이 플러그인
  이슈가 해소된 뒤 재시도한다.
  **AGP 8.x는 Gradle 9.6.0+와도 호환되지 않는다**(AGP 8.x가 쓰는 Gradle 내부 API가 9.6.0에서 제거됨,
  https://docs.gradle.org/current/userguide/upgrading_version_9.html 참조) — Gradle 래퍼는 9.5.x
  마지막 버전인 9.5.1로 고정한다. 9.6.0 이상으로 올리려면 AGP 9으로 먼저 전환해야 한다.
- 테스터 그룹(Google Group) 연결은 `scripts/play-testers.sh`로 한다. **반드시 `DRY_RUN=1`으로
  실제 track ID를 먼저 확인**한 뒤 커밋 — track ID 라벨과 실제 API ID가 다를 수 있어, 틀리면
  엉뚱한 트랙의 테스터 설정을 덮어쓴다.

## 아키텍처 메모

- **앱 ID / 패키지**: `com.geonganghaejim.app` (안드로이드 `applicationId`, iOS 번들 ID).
  구 패키지명 `site.tobehealthy.webview`에서 최근 변경되었으니, 문서·스크린샷·외부 문서에서
  옛 이름을 보면 이관 흔적으로 이해한다.
- **웹뷰 → 네이티브 브릿지**: 웹 쪽에서 `window.flutter_inappwebview.callHandler('Channel', memberId)`로
  로그인한 회원 ID를 보내면(`lib/main.dart`의 `onWebViewCreated`), 네이티브가
  `FlutterSecureStorage`에 `memberId`를 저장하고 FCM 토큰을 발급해 `POST /api/v1/push/webview`로
  전송한다(`sendTokenToServer`). FCM 토큰이 리프레시될 때도 저장된 `memberId`로 같은 엔드포인트에
  재전송한다 — 이 흐름이 깨지면 로그인은 되는데 푸시만 안 오는 형태로 나타난다.
- **Firebase는 FCM 전용.** Analytics 수집(`firebase_analytics_collection_enabled`)과
  FCM auto-init은 `AndroidManifest.xml`에서 의도적으로 꺼져 있다(`false`) — 켜져 있는 걸 보면
  실수로 되돌아간 것.
- **뒤로가기 처리**: `PopScope(canPop: false)` + `_handleBack()`으로 항상 가로챈다. 웹뷰 히스토리가
  있으면 웹뷰 안에서 뒤로 이동, 없으면 2초 내 두 번 눌러야 앱 종료(토스트 안내). 이 로직을
  건드릴 때는 두 경로(히스토리 있음/없음) 모두 실기기에서 확인한다.
- **iOS/Android 네이티브 레이어는 거의 비어 있다** — `MainActivity.kt`는 `FlutterActivity` 상속뿐,
  `AppDelegate.swift`는 Firebase 초기화 + 플러그인 등록뿐. 커스텀 네이티브 코드를 추가하기 전에
  정말 네이티브가 필요한 요구사항인지(웹에서 안 되는 것인지) 먼저 확인한다.
- Firebase 프로젝트 설정(`firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist`)은
  `firebase.json`의 FlutterFire 설정에서 생성된 산출물이다 — 직접 손으로 고치지 말고
  `flutterfire configure`로 재생성한다.
