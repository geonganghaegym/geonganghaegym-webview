# Play 배포 자동화 (브라우저 조작 대체)

Play Console을 브라우저로 클릭하던 작업 중 **릴리스 절반**을 Google Play Developer API로 옮긴 설정이다.
Gradle Play Publisher(GPP) 3.13.0을 사용한다.

## 왜

Playwright MCP로 Play Console을 조작하면 클릭 한 번마다 페이지 전체가 접근성 트리로 되돌아온다.
실측: 스냅샷 263개 / 3.4MB(토큰 90만 안팎), 그중 Play Console이 190개 / 2.1MB.
좌측 메뉴 트리("테스트 및 출시")만 293번 재전송됐다. 느린 원인은 클릭 속도가 아니라 이 토큰량이다.

## 검증된 환경

| 항목 | 값 |
|---|---|
| GPP | **3.13.0** (4.x는 AGP 9.0.0+ 요구 → 현재 AGP 8.13.2에서 적용 실패) |
| Gradle / AGP | 9.5.1 / 8.13.2 — `./gradlew :app:tasks --all`로 `publishBundle` 등 GPP 태스크가
  실제 등록되는 것까지 확인(2026-09-27, `play-service-account.json` 없이도 태스크는 등록됨).
  같은 날 AGP 9.4.0+GPP 4.1.1 전환을 시도했으나 `flutter_inappwebview_android` 1.1.3(당시 pub 최신)이
  AGP 9에서 제거된 `getDefaultProguardFile('proguard-android.txt')`를 호출해 `assembleDebug`에서
  실패(첫 차단 요인, 그 이후 단계는 미확인), AGP 8.13.2 유지.
  AGP 8.x는 Gradle 9.6.0+와 비호환(내부 API 제거)이라 Gradle은 9.5.x 최신인 9.5.1로 고정 |
| 적용 위치 | `android/settings.gradle`(플러그인 선언), `android/app/build.gradle`(`play {}` 블록) |
| 자격증명 | `android/play-service-account.json` (gitignore 처리됨, **없으면 자동 비활성화**) |

## 1회 준비: 서비스 계정

1. GCP에서 서비스 계정 + 키 생성 (프로젝트는 아래 중 선택)
   ```sh
   gcloud iam service-accounts create play-publisher \
     --display-name="Play Publisher" --project=<PROJECT_ID>
   gcloud iam service-accounts keys create android/play-service-account.json \
     --iam-account=play-publisher@<PROJECT_ID>.iam.gserviceaccount.com
   ```
2. **Play Console에서 연결** (여기는 브라우저 필수):
   Play Console → 설정 → API 액세스 → 위 서비스 계정 연결 → 권한 부여
   (필요 권한: 앱 정보 보기, 프로덕션·테스트 트랙으로 출시)
3. 권한 전파에 수 분 걸린다.

## 명령어

```sh
# AAB 빌드 (release 서명은 android/key.properties 사용)
flutter build appbundle --release

# 내부 테스트에 초안으로 업로드 (build.gradle 기본값)
cd android && ./gradlew publishBundle --console=plain

# 비공개 테스트(Alpha)로 업로드
./gradlew publishBundle --track=alpha --release-status=completed --console=plain

# 프로덕션 출시 (단계적 배포 10%)
./gradlew publishBundle --track=production --release-status=inProgress --user-fraction=0.1

# 이미 올라간 버전을 트랙 간 승격 (재업로드 없음)
./gradlew promoteArtifact --from-track=alpha --promote-track=production --release-status=completed

# 실제 반영 없이 검증만
./gradlew publishBundle --no-commit
```

검증된 주요 옵션: `--track` `--release-status` `--user-fraction` `--release-name`
`--version-code` `--update-priority` `--no-commit` `--artifact-dir`

스토어 등재정보(설명·스크린샷)도 파일로 관리 가능하다. 기존 Play Console 내용을 먼저 내려받는다:

```sh
./gradlew bootstrapListing   # → android/app/src/main/play/ 생성
./gradlew publishListing     # 수정 후 업로드
```

## 테스터 그룹 연결 (브라우저 불필요)

GPP는 테스터 관리를 노출하지 않지만, Play Developer API의 `edits.testers`가 트랙별
Google Group 연결을 지원한다 (`googleGroups[]` 필드). `scripts/play-testers.sh`가 이를 감싼다:

```sh
# 처음에는 반드시 DRY_RUN으로 실제 track ID를 확인한다 (커밋 생략)
DRY_RUN=1 ./scripts/play-testers.sh alpha geonganghaegym-testers@googlegroups.com

# 확인한 track ID로 실행
./scripts/play-testers.sh <실제-track-id> geonganghaegym-testers@googlegroups.com
```

**`alpha`는 추측값이다.** Play Console 표시 라벨("비공개 테스트 - Alpha")과 API track ID는
별개이고, 커스텀 클로즈드 트랙이면 ID가 다르다. 틀린 track으로 커밋하면 엉뚱한 트랙의
테스터 설정을 덮어쓴다. `DRY_RUN=1`이 `GET .../edits/{editId}/tracks`로 실제 ID를 출력한다.

동작: edit 생성 → `PUT .../edits/{editId}/testers/{track}` → `:commit`.
gcloud 전역 설정을 건드리지 않도록 임시 `CLOUDSDK_CONFIG`에서 서비스 계정을 인증한다.

제약:
- **Google Group만 가능하다.** Play Console UI의 개별 이메일 목록(email list)은 API 미지원.
- 편집(edit)은 계정당 하나만 열 수 있다. 새로 열면 기존 편집이 무효화된다.
- 그룹 자체의 멤버 추가(googlegroups.com)는 개인 계정 그룹이라 Admin SDK로 안 되고 브라우저가 필요하다.
- 스크립트의 문법·가드 분기는 검증했으나 **API 호출부는 키 발급 후 첫 실행에서 확인해야 한다.**

## API로 되지 않는 것 (브라우저 필요)

- **프로덕션 액세스 신청 설문** — Play Console UI 전용
- 비공개 테스트 14일 / 테스터 12명 요건 확인 화면
- 앱 무결성, 국가/지역 설정 일부
- 테스터 **개별 이메일 목록**(그룹은 API 가능 — 위 절 참고)
- googlegroups.com 그룹의 멤버 추가
- **네이버 품앗이 카페 글·댓글** — 공개 API 없음

## 브라우저를 쓸 때의 최적화

### MCP 서버 옵션 (적용됨)

`@playwright/mcp` 0.0.78은 기본값이 전부 "응답에 다 담기"다. 프로젝트 `.mcp.json`에
아래 옵션을 준 서버를 등록하고, `~/.claude/settings.json`의
`playwright@claude-plugins-official`을 `false`로 내려 교체했다.

이 비활성화는 **전역**이다(의도된 범위). 교체 서버는 이 레포의 `.mcp.json`에만 있으므로,
webview 밖의 프로젝트에서는 Playwright MCP가 뜨지 않는다. 다른 레포에서 필요해지면
그 레포에 같은 `.mcp.json`을 두면 된다.

| 옵션 | 기본값 | 이유 |
|---|---|---|
| `--output-mode file` | `stdout` | 스냅샷·콘솔·네트워크를 파일로. 응답엔 경로만 온다 |
| `--output-dir ~/.cache/playwright-mcp-out` | `.playwright-mcp` | 산출물을 레포 밖으로 |
| `--console-level error` | 전체 | INFO/WARNING 노이즈 제거. **CSP 에러 자체는 `[ERROR]`라 남는다** — 그 151KB 로그를 응답 밖으로 빼는 건 `--output-mode file` 쪽이다 |
| `--image-responses omit` | `allow` | 스크린샷 이미지 응답 생략 |
| `--block-service-workers` | 끔 | 불필요한 워커 차단 |
| `--user-data-dir <기존 프로필>` | 자동 해시 경로 | **로그인·2FA 유지의 핵심.** 옵션이 바뀌면 프로필 해시 경로도 바뀌어 재로그인이 필요해지므로 명시했다 |

일부러 넣지 않은 것:
- `--snapshot-mode none`: 토큰 절감은 가장 크지만 요소 `ref`가 안 와서 `browser_click`류를
  못 쓴다. `browser_run_code_unsafe` 배치 전용으로 갈 때만 켠다.
- `--mobile`: 카페엔 유리하지만 Play Console 모바일 웹은 기능이 잘릴 수 있다.
- `--isolated`: 프로필을 디스크에 저장하지 않아 로그인 쿠키가 날아간다.

`.mcp.json`은 개인 홈 절대경로가 들어 있어 gitignore 처리했다.

**적용 순서** — 플러그인을 껐다고 이미 떠 있는 브라우저가 종료되는 건 아니다. 새 서버도 같은
프로필을 가리키므로 락이 남아 있으면 똑같이 `Browser is already in use`가 난다:

1. 그 프로필을 쓰는 다른 Claude 세션을 정리한다.
2. 락이 사라졌는지 확인한다 (심볼릭 링크가 없어야 한다):
   ```sh
   ls -l ~/Library/Caches/ms-playwright-mcp/mcp-chrome-5df09a9/SingletonLock
   ```
3. 이 세션을 재시작한다 (MCP 설정은 재시작 시 로드된다).
4. 프로젝트 MCP 서버 신뢰 승인 프롬프트를 승인한다.
5. Play Console을 열어 로그인이 유지됐는지 확인한다 (프로필이 맞는지 여기서 판명된다).

### 브라우저 조작 패턴

**딥링크로 직행** — 메뉴 클릭 체인이 곧 스냅샷 개수다.
개발자 ID는 `8629066469075651458`. 계정에 앱이 둘 있고 ID는 `4972477758452389725`,
`4973351030666655604` 인데 **어느 쪽이 이 앱(`com.geonganghaejim.app`)인지는 미확인**이다
(대조 근거였던 스냅샷을 삭제함). Play Console에서 확인 후 아래를 채울 것.

```
https://play.google.com/console/u/0/developers/<devId>/app/<appId>/tracks/production
                                                              .../tracks/closed-testing
                                                              .../tracks/internal-testing
                                                              .../app-integrity
                                                              .../countries
```

**액션을 배치로 묶어 스냅샷을 받지 않는다** — `browser_run_code_unsafe`로 탐색·클릭·입력·검증을
한 번에 하고 상태 문자열만 반환받는다. 왕복 5~10회와 스냅샷 5~10장이 1회/0장이 된다.

```js
async (page) => {
  await page.goto('https://play.google.com/console/u/0/developers/8629066469075651458/app/<appId>/tracks/closed-testing');
  await page.getByRole('button', { name: '테스터' }).click();
  await page.getByRole('textbox', { name: /이메일/ }).fill('geonganghaegym-testers@googlegroups.com');
  await page.getByRole('button', { name: '저장' }).click();
  return await page.getByRole('status').first().textContent();
}
```

그 외:
- 전체 스냅샷 대신 `browser_find`로 필요한 요소만 찾는다.
- 네이버 카페는 `m.cafe.naver.com` 모바일 웹을 쓴다 (PC 버전이 188KB 최대 스냅샷의 주범, iframe 중첩도 없음).
- 로그인/2FA는 이미 재사용된다 (MCP가 `--isolated` 없이 실행 → persistent profile).
  `--isolated`를 붙이면 쿠키가 사라져 오히려 손해다.
- 네이버는 병렬화·고속 반복하지 않는다 (자동화 탐지·rate limit).

## 위생

`.playwright-mcp/`는 로그인된 세션의 접근성 덤프(테스터 그룹 이메일·계정명 포함)가 쌓이는 곳이다.
gitignore 처리했다. 커밋에 섞이지 않는지 확인:

```sh
git check-ignore -v .playwright-mcp/probe.yml
```
