#!/bin/zsh
# 용량 줄이기 시험용 폴더를 만든다: zsh make_shrink_fixture.sh <출력 폴더>
# macOS에 들어 있는 배경화면 사진·영상을 재료로 쓴다.
set -e
out="$1/홍보 자료"
rm -rf "$out"
mkdir -p "$out/사진" "$out/영상" "$out/문서" "$out/소리"
heic="/System/Library/Desktop Pictures/iMac Silver.heic"
cp "$heic" "$out/사진/원본 사진.heic"
sips -s format jpeg -s formatOptions 95 "$heic" --out "$out/사진/바다 풍경.jpg" >/dev/null
sips -s format png "$heic" --out "$out/사진/스크린샷.png" >/dev/null
sips -s format tiff -Z 2400 "$heic" --out "$out/사진/스캔.tiff" >/dev/null
swift "${0:A:h}/make_video.swift" "$out/영상/소개 영상.mov" 8 >/dev/null 2>&1
sips -s format pdf "$out/사진/바다 풍경.jpg" --out "$out/문서/제품 소개서.pdf" >/dev/null
python3 "${0:A:h}/make_docx.py" "$out/사진/바다 풍경.jpg" "$out/문서/보고서.docx"
say -o "$out/소리/녹음.aiff" "안녕하세요. 파인더리 용량 줄이기 시험 녹음입니다. 이 녹음은 무손실 형식이라 크기가 큽니다."
print "메모" > "$out/메모.txt"
print -r -- "$out"
