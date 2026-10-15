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

## 빌드

```bash
./build.sh            # Zippie.app 생성
swift build -c release --product zippie-cli   # 시험용 명령줄 도구
```

## 구조

| 경로 | 내용 |
|---|---|
| `Sources/ZipCore` | ZIP 읽기/쓰기, 병렬 압축, 인코딩 처리 |
| `Sources/Zippie` | SwiftUI 앱 |
| `Sources/ZippieCLI` | 시험용 명령줄 도구 (`zippie-cli zip/unzip/list`) |
| `Sources/CLibdeflate` | libdeflate v1.24 (MIT). Zippie용 수정 사항은 `VERSION.txt` 참고 |
| `windows-test` | Windows 호환성 시험 묶음 (`make_pack.sh` → `serve.py` → VM에서 `run.ps1`) |

## 라이선스 표기

libdeflate — Copyright 2016 Eric Biggers, Copyright 2024 Google LLC — MIT License (`Sources/CLibdeflate/LICENSE`)
