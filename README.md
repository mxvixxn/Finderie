# Zippie

Mac용 ZIP 압축 앱. Windows와 주고받을 때 한글 파일 이름이 깨지지 않게 하는 데 초점을 맞췄다.

## 기능

- **한글 이름 호환**: 압축할 때 이름 인코딩을 고를 수 있다.
  - Windows 호환 · UTF-8 (권장): 완성형(NFC) + UTF-8 표시
  - 구형 Windows 호환 · CP949: CP949 이름 + 원래 이름(Info-ZIP 유니코드 경로 필드)
  - Mac 기본 방식: Mac의 '압축하기'와 같음 (Windows에서 깨짐)
- **압축 풀기 인코딩 자동 감지**: UTF-8 / CP949(Windows) / 표시 없는 UTF-8(Mac)
- **빠른 압축**: libdeflate 엔진, 멀티코어 병렬 압축, 압축과 디스크 쓰기 동시 진행
- **큰 파일 병렬 풀기**: 큰 파일은 서로 독립된 조각으로 압축하고 조각 색인(보조 필드 0x5A50)을 남긴다. 다른 프로그램에서는 평범한 ZIP으로 열린다.
- **이미 압축된 파일은 그대로 담기**: 사진·영상·zip 등
- **Zip64**: 4GB 넘는 파일·압축 파일, 65,535개 넘는 파일
- **백그라운드 모드**, **외장 드라이브 자동 감지(순차 읽기)**

## Finder에서 바로 쓰기

파일이나 폴더를 우클릭 → **Zippie로 압축** / **Zippie로 풀기**(ZIP을 골랐을 때).
압축은 지금 설정(한글 이름 방식, 속도)대로 바로 하고, 풀기는 미리보기 없이 기본 풀 위치에 푼다.

- 메뉴 맨 위에 나오는 항목은 Finder 확장(`Extension/`, 앱 안의 `ZippieFinder.appex`)이 넣는다.
  처음 한 번 시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → Zippie(파일 제공자)에서 켠다.
- 확장은 샌드박스 안에서 돌기 때문에 고른 경로를 `zippie://` 주소로 앱에 넘긴다. 확장만 아는 비밀 값을
  함께 보내고 앱이 확인하므로, 웹사이트 같은 다른 곳에서 이 주소를 열어도 아무 일도 일어나지 않는다.
- 같은 기능이 **빠른 동작 / 서비스** 메뉴에도 있다(시스템 설정 → 키보드 → 키보드 단축키 → 서비스).

## 빌드

```bash
./build.sh            # Zippie.app 생성
swift build -c release --product zippie-cli   # 시험용 명령줄 도구
```

## 구조

| 경로 | 내용 |
|---|---|
| `Sources/ZipCore` | ZIP 읽기/쓰기, 병렬 압축, 인코딩 처리 |
| `Sources/Zippie` | 앱 진입점 (창, 설정 창, Dock으로 연 파일) |
| `Sources/ZippieUI` | 화면과 상태 모델: 놓는 칸, ZIP 미리보기, 작업 대기열·카드, 최근 기록, 설정 |
| `Sources/ZippieSnap` | 화면 확인 도구: 실제 작업을 돌려 각 상태를 PNG로 그린다 (`zippie-snap <출력> <작업 폴더>`) |
| `Sources/ZippieCLI` | 시험용 명령줄 도구 (`zippie-cli zip/unzip/list`) |
| `Sources/CLibdeflate` | libdeflate v1.24 (MIT). Zippie용 수정 사항은 `VERSION.txt` 참고 |
| `windows-test` | Windows 호환성 시험 묶음 (`make_pack.sh` → `serve.py` → VM에서 `run.ps1`) |

## 라이선스 표기

libdeflate — Copyright 2016 Eric Biggers, Copyright 2024 Google LLC — MIT License (`Sources/CLibdeflate/LICENSE`)
