# 한글 이름 시험 데이터 (Mac처럼 NFD로 저장), 큰 로그 파일, 영상 흉내 파일을 만든다.
import os, sys, random, unicodedata as u
root = sys.argv[1]; nfd = lambda s: u.normalize('NFD', s)
k = os.path.join(root, nfd('한글 테스트'))
os.makedirs(os.path.join(k, nfd('하위 폴더'), nfd('더 깊은 폴더')), exist_ok=True)
os.makedirs(os.path.join(k, nfd('빈 폴더')), exist_ok=True)
files = {
    '보고서 최종.txt': '최종 보고서입니다\n' * 100,
    '하위 폴더/사진 설명.md': '# 사진 설명\n가족 여행\n',
    '하위 폴더/더 깊은 폴더/깊은 파일.txt': '깊이 3\n',
    '삶의 읊조림 닭갈비 뷁.txt': '겹받침과 드문 글자\n',
    '한자 漢字 일본어 ひらがな.txt': '한자와 가나\n',
    '이모지😀파일.txt': '이모지\n',
    '콜론:들어간 이름.txt': '윈도우 금지 문자\n',
    '괄호 (1) [대괄호] #번호 & 기호.txt': '특수문자\n',
    'English only.txt': 'ascii\n',
}
for name, data in files.items():
    with open(os.path.join(k, *[nfd(p) for p in name.split('/')]), 'w') as f: f.write(data)
open(os.path.join(k, '.DS_Store'), 'w').write('junk')
random.seed(5)
words = ['요청', '처리', '완료', '사용자', '파일', '압축', '오류없음', '서버', '응답']
with open(os.path.join(root, nfd('큰 로그 파일.log')), 'w') as f:
    for i in range(700000): f.write(f'{i:07d} {random.choice(words)} {random.choice(words)} id={random.randint(0,99999)}\n')
with open(os.path.join(root, nfd('영상 클립.mp4')), 'wb') as f: f.write(os.urandom(24 * 1024 * 1024))
