#!/bin/zsh
# Windows 호환성 시험 묶음(zips/, expected/)을 다시 만든다. 약 5GB 임시 공간이 필요하다.
#   ./make_pack.sh   →   python3 serve.py <VMware 내부망 IP>   →   VM에서 run.ps1 실행
set -euo pipefail
cd "$(dirname "$0")"
CLI="$PWD/../.build/release/finderie-cli"
[ -x "$CLI" ] || (cd .. && swift build -c release --product finderie-cli)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rm -rf zips expected; mkdir -p zips "$TMP/src" "$TMP/z64"
python3 tools/make_korean_data.py "$TMP/src"
cd "$TMP/src"
"$CLI" zip utf8  "$OLDPWD/zips/1_UTF8_권장.zip" "한글 테스트"
"$CLI" zip cp949 "$OLDPWD/zips/2_CP949_구형윈도우.zip" "한글 테스트"
"$CLI" zip mac   "$OLDPWD/zips/3_Mac기본방식_깨짐예상.zip" "한글 테스트"
"$CLI" zip utf8  "$OLDPWD/zips/4_큰파일_조각압축.zip" "큰 로그 파일.log"
"$CLI" zip utf8  "$OLDPWD/zips/5_영상_저장방식.zip" "영상 클립.mp4"
"$CLI" zip utf8  "$OLDPWD/zips/8_금지이름_자동고침.zip" "윈도우 금지 이름"
cd "$OLDPWD"
python3 tools/make_zip64_data.py "$TMP/z64"
(cd "$TMP/z64" && "$CLI" zip utf8 "$OLDPWD/zips/6_Zip64_4.5GB파일.zip" "4.5GB 대용량 파일.bin" && "$CLI" zip utf8 "$OLDPWD/zips/7_Zip64_7만개파일.zip" 칠만개)
python3 tools/make_expected.py "$PWD"
