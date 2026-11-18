# ACG 앱 (Flutter)

윈도우 데스크톱과 안드로이드용 편집 앱입니다. 보정은 `../engine` Rust 엔진이 수행합니다(dart:ffi).

## 윈도우에서 실행

필요: Flutter, Rust(rustup, MSVC 툴체인), Visual Studio "C++ 데스크톱 개발" 워크로드.

```
cd app
flutter pub get
flutter run -d windows        # 개발 실행
flutter build windows         # 배포용 → build/windows/x64/runner/Release/
```

윈도우 빌드 시 CMake가 `cargo build --release`로 엔진을 함께 빌드하고 `photo_grade_engine.dll`을 exe 옆에 넣습니다.

## 화면 구성

- 자동: 사진 분석 → 자동 보정 + 장면에 맞는 스타일 후보, 적용 강도 조절
- 템플릿: 기본 14종, 내 템플릿 저장/삭제, `.json` 템플릿과 `.cube` LUT 가져오기, 내보내기(공유)
- 빛 / 색상(HSL 8색) / 커브(RGB·채널별) / 그레이딩(섀도우·미드톤·하이라이트) / 효과
- AI: Gemini · Claude · ChatGPT 중 선택 + 본인 API 키. 자연어 요청, 참조 사진 따라하기, 보정 가이드 링크
- 길게 누르기 또는 비교 버튼: 원본 보기 · Ctrl+Z/Y 실행 취소 · Ctrl+O 열기 · Ctrl+E 내보내기

## 테스트

```
cd ../engine && cargo build --release
cd ../app && ACG_SAMPLE=사진경로 flutter test   # 윈도우: engine/target/release 를 PATH에 추가
```
