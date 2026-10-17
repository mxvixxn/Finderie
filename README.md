# Finderie

Windows로 파일을 보내기 전에 쓰는 Mac 도구. 받는 사람 컴퓨터에서 한글 이름이나 내용이 깨지지 않게 미리 고친다.
압축(ZIP)은 그 옆의 부가 기능이다.

## 보내기 준비 (압축 없이)

파일이나 폴더를 놓으면 먼저 검사해서 보고서를 보여 주고, 고칠 항목을 켜고 끈 뒤 고친다.

- **이름**: 자모가 풀린 한글(NFD → NFC), Windows에서 못 쓰는 글자(`\ / : * ? " < > |`), 예약된 이름(CON, AUX, COM1…),
  끝의 점·공백, 고친 뒤 겹치는 이름(대소문자 무시)
- **Mac 숨김 파일**: `.DS_Store`, `._파일`, `__MACOSX`
- **CSV**: BOM 없는 UTF-8이고 한글이 있으면 BOM을 붙여 Excel에서 깨지지 않게 (CP949 CSV는 그대로)
- **HEIC 사진 → JPG** (사진 정보 유지)
- **개인정보 지우기**: 사진의 위치(GPS)·카메라 정보(제조사·모델·일련번호), 영상의 촬영 위치, PDF 작성자,
  Office 문서의 작성자·마지막 수정자·회사. 사진과 영상은 다시 압축하지 않고 정보만 빼서 화질이 그대로고,
  촬영 날짜와 방향은 남긴다 (`Sources/ZipCore/Privacy.swift`)
- **경고만**: Pages·Numbers·Keynote 문서, 인터넷 바로가기, 앱·설치 파일, 가상본·링크, 260자 넘는 경로

저장 방식은 매번 고른다. **복사본 만들기**는 원본 옆 `Windows로 보낼 파일` 폴더에, **원본 고치기**는 확인 후 이름을
직접 바꾸고 지우는 파일은 휴지통으로 옮긴다. 끝나고 ZIP으로 묶을 수도 있다.

macOS의 Foundation 파일 API는 새 이름을 자모로 풀어(NFD) 저장하므로, 이름을 만들고 바꾸는 일은 POSIX 함수로 한다
(`Sources/ZipCore/SendPrep.swift`).

## 용량 줄이기

메일·메신저 첨부 한도에 맞게 파일을 줄인다. 단계(조금 / 적당히 / 많이)를 고르면 결과 크기를 미리 예상해 보여 준다.

| 종류 | 하는 일 |
|---|---|
| 사진 (JPG·HEIC·PNG·TIFF·BMP) | 긴 변 3840 / 2560 / 1600px, 화질 낮추기. TIFF·BMP는 JPG로. 사진 정보 유지 |
| 영상 (MOV·MP4·M4V) | H.264 MP4 1080p / 720p / 540p로 다시 인코딩 |
| PDF | 안의 이미지 해상도·화질 낮추기 (미리보기의 '파일 크기 줄이기'와 같은 Quartz 필터) |
| Office 문서 (docx·pptx·xlsx) | 풀어서 `media` 폴더의 사진만 줄이고 다시 묶기 |
| 소리 (WAV·AIFF) | M4A(AAC)로 |

5% 넘게 작아지지 않는 파일은 그대로 둔다. **복사본 만들기**는 `용량 줄인 파일` 폴더에, **원본 바꾸기**는 원래 파일을
휴지통으로 옮긴다 (`Sources/ShrinkCore`).

## 압축 기능

- **압축 전 옵션 확인**: 파일을 놓으면 한글 이름 방식 · 속도 · Mac 숨김 파일 빼기 · 저장 위치를 확인하고 압축한다 (설정에서 끌 수 있다)
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

파일이나 폴더를 우클릭 → **Windows로 보낼 준비** / **Finderie로 용량 줄이기** / **Finderie로 압축** / **Finderie로 풀기**(ZIP을 골랐을 때).
압축은 지금 설정(한글 이름 방식, 속도)대로 바로 하고, 풀기는 미리보기 없이 기본 풀 위치에 푼다.

- 메뉴 맨 위에 나오는 항목은 Finder 확장(`Extension/`, 앱 안의 `FinderieExtension.appex`)이 넣는다.
  처음 한 번 시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → Finderie(파일 제공자)에서 켠다.
- 확장은 샌드박스 안에서 돌기 때문에 고른 경로를 `finderie://` 주소로 앱에 넘긴다. 확장만 아는 비밀 값을
  함께 보내고 앱이 확인하므로, 웹사이트 같은 다른 곳에서 이 주소를 열어도 아무 일도 일어나지 않는다.
- 같은 기능이 **빠른 동작 / 서비스** 메뉴에도 있다(시스템 설정 → 키보드 → 키보드 단축키 → 서비스).

## 빌드

```bash
./build.sh            # Finderie.app 생성
swift build -c release --product finderie-cli   # 시험용 명령줄 도구
.build/release/finderie-cli scan <파일...>        # 보내기 준비 검사만
python3 windows-test/make_prep_fixture.py <폴더>  # 문제가 고루 섞인 시험 폴더 만들기
.build/release/finderie-cli shrink --dry <파일...>   # 용량 줄이기 예상만
zsh windows-test/make_shrink_fixture.sh <폴더>     # 사진·영상·PDF·문서·소리 시험 폴더 만들기
```

## 구조

| 경로 | 내용 |
|---|---|
| `Sources/ZipCore` | ZIP 읽기/쓰기, 병렬 압축, 인코딩 처리 |
| `Sources/Finderie` | 앱 진입점 (창, 설정 창, Dock으로 연 파일) |
| `Sources/FinderieUI` | 화면과 상태 모델: 놓는 칸, ZIP 미리보기, 작업 대기열·카드, 최근 기록, 설정 |
| `Sources/FinderieSnap` | 화면 확인 도구: 실제 작업을 돌려 각 상태를 PNG로 그린다 (`finderie-snap <출력> <작업 폴더>`) |
| `Sources/FinderieCLI` | 시험용 명령줄 도구 (`finderie-cli zip/unzip/list`) |
| `Sources/CLibdeflate` | libdeflate v1.24 (MIT). Finderie용 수정 사항은 `VERSION.txt` 참고 |
| `windows-test` | Windows 호환성 시험 묶음 (`make_pack.sh` → `serve.py` → VM에서 `run.ps1`) |

## 라이선스 표기

libdeflate — Copyright 2016 Eric Biggers, Copyright 2024 Google LLC — MIT License (`Sources/CLibdeflate/LICENSE`)
