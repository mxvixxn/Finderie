#!/usr/bin/env python3
"""보내기 준비 시험용 폴더를 만든다: python3 make_prep_fixture.py <출력 폴더>"""
import os, sys, subprocess, unicodedata, shutil

out = sys.argv[1]
root = os.path.join(out, "제안서 자료")
if os.path.exists(root):
    shutil.rmtree(root)
nfd = lambda s: unicodedata.normalize("NFD", s)

def put(rel, data=b"x", raw=False):
    path = os.path.join(root, rel if raw else rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path.encode() if isinstance(path, str) else path, "wb") as f:
        f.write(data)

os.makedirs(root)
# 자모가 풀린(NFD) 이름 — Mac에서 만든 파일이 흔히 이렇다
os.makedirs(os.path.join(root, nfd("회의록")).encode())
with open(os.path.join(root, nfd("회의록"), nfd("3월 회의록.txt")).encode(), "wb") as f:
    f.write("회의 내용".encode())
with open(os.path.join(root, nfd("견적서 최종.pdf")).encode(), "wb") as f:
    f.write(b"%PDF-1.4\n")
# Windows에서 못 쓰는 글자, 예약된 이름, 끝의 점
put("일정:초안.txt")          # Finder에서는 "일정/초안.txt"로 보인다
put("질문?.txt")
put("CON.txt")
put("메모.")
# 고치고 나면 이미 있는 이름과 겹치는 경우 ("일정:초안.txt" → "일정-초안.txt")
put("일정-초안.txt", b"B")
# Mac 숨김 파일
put(".DS_Store", b"\0")
put("._견적서 최종.pdf", b"\0")
# CSV: UTF-8(BOM 없음, 한글) / ASCII / CP949
put("고객 명단.csv", "이름,전화\n김철수,010-0000-0000\n".encode("utf-8"))
put("numbers.csv", b"a,b\n1,2\n")
put("예전 명단.csv", "이름,전화\n이영희,02\n".encode("cp949"))
# HEIC 사진
png = os.path.join(out, "_tmp.png")
subprocess.run(["sips", "-s", "format", "png", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns", "--out", png], capture_output=True)
subprocess.run(["sips", "-s", "format", "heic", png, "--out", os.path.join(root, "현장 사진.HEIC")], capture_output=True)
os.remove(png)
# Mac 전용 파일
put("발표.key", b"PK")
put("참고 사이트.webloc", b"<plist/>")
os.symlink("견적서 최종.pdf", os.path.join(root, "바로가기"))
# 아주 긴 경로
deep = os.path.join(root, *(["아주 긴 폴더 이름입니다 정말로 깁니다"] * 10))
os.makedirs(deep)
put(os.path.join(deep, "끝에 있는 파일.txt"))
# 개인정보가 든 파일 (사진 위치·카메라, PDF 작성자, 영상 위치, Word 작성자)
here = os.path.dirname(os.path.abspath(__file__))
subprocess.run(["swift", os.path.join(here, "make_private_files.swift"), root], capture_output=True)
subprocess.run(["python3", os.path.join(here, "make_docx.py"), os.path.join(root, "위치 사진.jpg"),
                os.path.join(root, "분기 보고서.docx"), "김철수"], capture_output=True)
print(root)
