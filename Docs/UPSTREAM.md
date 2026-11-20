# LineageOS Twelve 참고 이력

이 문서는 LiquidTune의 초기 포트에서 조사하고 참고한 내용을 기록합니다. 현재 앱의 기능은 README에서 확인할 수 있습니다.

2026년 11월 19일 확인한 LineageOS 24.0 공식 릴리스의 `lineage-24.0` 브랜치를 기준으로 했습니다. 분석 커밋은 `bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac`입니다. 공식 변경 기록에는 대형 음악 라이브러리 로딩 개선, Activity의 재생 빈도별 앨범·장르, 오디오 오프로드 수정과 Jellyfin 개선이 기재되어 있습니다. [LineageOS 24.0 발표](https://lineageos.org/Changelog-32/) · [고정 리비전](https://github.com/LineageOS/android_packages_apps_Twelve/tree/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac)

Android Central에 게재된 LineageOS 제공 실제 Twelve 스크린샷에서는 어두운 테마, 공급자 선택, Activity의 앨범 카드, Library 탭과 앨범 상세의 곡 목록을 확인했습니다. 해당 화면은 22.1 버전입니다. 24.0의 렌더링과 제스처 타이밍은 기기에서 직접 관찰하지 못했으므로 아래 화면 분석에는 24.0의 XML, Kotlin, 색상·아이콘 리소스를 사용했습니다. [스크린샷이 포함된 기사](https://www.androidcentral.com/apps-software/lineageos-22-1-based-on-android-15-is-already-available-for-over-100-devices)

| 항목 | 24.0에서 확인한 구성 | iOS 0.1.0 |
| --- | --- | --- |
| 내비게이션 | Activity, Search, Library. 가로 XML은 Material NavigationRailView 사용 | 하단 탭 및 넓은 화면의 좌측 레일. 라이브러리에 Songs 탭 추가 |
| Activity와 Library | 공급자별 Activity 데이터, Library의 Albums·Artists·Genres·Playlists, 2열 기준의 적응형 앨범 그리드 | 사용 중인 소스의 로컬 청취 이력과 앨범 섹션, 열 수가 적응하는 앨범 그리드, 아티스트·장르·곡 |
| Now Playing | 16dp 모서리 앨범 아트, 진행률, 72dp 주요 버튼 스타일, 셔플·반복 상태 점, 하단 액션 바 | 같은 순서의 수송 컨트롤과 Material 계열 커스텀 컴포넌트. 가로에서는 앨범 아트와 컨트롤을 나란히 배치 |
| 미니 플레이어 | 56dp 썸네일, 제목·아티스트·앨범, 버퍼링·재생 버튼. 공통 slideUp 250ms, slideDown 200ms 및 페이드 확인 | 56pt 썸네일, 동일 정보와 상태. 커스텀 SwiftUI 슬라이드·페이드와 두 화면 간 아트 이동. Android 제스처·이징과 직접 비교 미실시 |
| 테마 | Material3Expressive DayNight, Android의 DynamicColors, 테마 속성에 따른 surface·primary·tertiary 계열 | 실제 Roboto와 원본 벡터 일부를 사용. 앨범 아트의 주요 색을 추출해 밝고 어두운 팔레트 생성. Android의 시스템 팔레트와 정확한 색상 일치는 별도 검증 대상 |
| 재생·라이브러리 | AndroidX Media3 ExoPlayer, MediaLibraryService, MediaRepository·ProvidersRepository, 파일·MediaStore·서버 공급자 | UIKit 오디오 출력 피커, AVPlayer·AVAudioSession·MediaPlayer, Files 가져오기와 로컬 인덱스, Swift REST 공급자 |
| 검색·플레이리스트·큐 | 공급자별 검색 및 기능 협상, 큐와 재개용 플레이리스트, 공급자에 따른 플레이리스트·즐겨찾기 쓰기 | 서버 검색과 로컬 메타데이터 검색, 로컬 플레이리스트 쓰기, 서버 리스트 열람, 큐 편집·복원 |
| 서버 | Jellyfin, Subsonic / OpenSubsonic / Navidrome, Ampache. OpenSubsonic 구조화 가사 지원 경로 존재 | Jellyfin 인증·직접 스트림, Subsonic 호환 API. Ampache, 구조화 가사, 서버 측 즐겨찾기·편집, scrobble은 미구현 |
| 시각화와 오디오 옵션 | Android Visualizer의 FFT·파형을 NierVisualizer에 전달, 재생 속도 0.5–4× 및 피치 0.5–1.5 | 로컬 파일의 실제 PCM 샘플을 기반으로 파형을 표시. 속도 0.5–2×. 스트림 파형, FFT 모드 전환, 독립 피치, 이퀄라이저, 무음 건너뛰기, 오프로드 설정은 미구현 |

## 원본 소스 위치

- 화면 구조와 값 리소스는 [res/layout](https://github.com/LineageOS/android_packages_apps_Twelve/tree/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/res/layout), [res/layout-land](https://github.com/LineageOS/android_packages_apps_Twelve/tree/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/res/layout-land), [themes.xml](https://github.com/LineageOS/android_packages_apps_Twelve/blob/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/res/values/themes.xml)에 있습니다.
- 재생 엔진과 큐 연동은 [PlaybackService.kt](https://github.com/LineageOS/android_packages_apps_Twelve/blob/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/java/org/lineageos/twelve/services/PlaybackService.kt)에 있습니다.
- 공급자 경계와 프로토콜별 코드는 [datasources](https://github.com/LineageOS/android_packages_apps_Twelve/tree/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/java/org/lineageos/twelve/datasources)에 있습니다.
- 플레이어 시각화와 속도·피치는 [VisualizerNVDataSource.kt](https://github.com/LineageOS/android_packages_apps_Twelve/blob/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/java/org/lineageos/twelve/ui/visualizer/VisualizerNVDataSource.kt), [PlaybackControlViewModel.kt](https://github.com/LineageOS/android_packages_apps_Twelve/blob/bc89c9e51509ac25e5c11e3ff6dfc5e47809b5ac/app/src/main/java/org/lineageos/twelve/viewmodels/PlaybackControlViewModel.kt)에 있습니다.
