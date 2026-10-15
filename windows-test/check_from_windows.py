# Windows에서 만든 ZIP을 Zippie로 풀고, Windows 쪽 원본 목록(win_expected.tsv)과 비교한다.
import hashlib, os, subprocess, sys, shutil, unicodedata as u, zipfile
W = os.path.dirname(os.path.abspath(__file__)); R = f'{W}/results'
CLI = os.path.join(W, '..', '.build', 'release', 'zippie-cli')
exp = {}
for line in open(f'{R}/win_expected.tsv', encoding='utf-8-sig'):
    k, name, md5, _ = line.rstrip('\n').split('\t'); exp[u.normalize('NFC', name)] = (k, md5)

def md5(p):
    m = hashlib.md5()
    with open(p, 'rb') as f:
        while b := f.read(1 << 20): m.update(b)
    return m.hexdigest()

for zn in [n for n in ['win_explorer.zip', 'win_dotnet.zip'] if os.path.exists(f'{R}/{n}')]:
    z = zipfile.ZipFile(f'{R}/{zn}')
    flags = {('UTF-8 표시' if i.flag_bits & 0x800 else '표시 없음') for i in z.infolist()}
    sample = [i for i in z.infolist() if any(ord(c) > 127 for c in i.orig_filename)][0]
    raw = sample.orig_filename.encode('utf-8' if sample.flag_bits & 0x800 else 'cp437')
    try: raw.decode('utf-8'); kind = 'UTF-8 바이트'
    except UnicodeDecodeError: kind = 'CP949 바이트' if raw.decode('cp949', 'ignore') else '?'
    extras = {hex(int.from_bytes(i.extra[p:p+2], 'little')) for i in z.infolist() for p in range(0, 0) } if False else set()
    print(f'■ {zn}: 이름 저장 방식 = {", ".join(flags)}, {kind}')
    out = f'{R}/unzipped_{zn[:-4]}'; shutil.rmtree(out, ignore_errors=True); os.makedirs(out)
    shutil.copy(f'{R}/{zn}', out)
    r = subprocess.run([CLI, 'unzip', zn], cwd=out, capture_output=True, text=True)
    print('  Zippie:', (r.stdout or r.stderr).strip().replace(out + '/', ''))
    got = {}
    for d, dirs, fs in os.walk(out):
        for n in dirs: got[u.normalize('NFC', os.path.relpath(os.path.join(d, n), out))] = ('D', '-')
        for n in fs:
            if n == zn: continue
            p = os.path.join(d, n); got[u.normalize('NFC', os.path.relpath(p, out))] = ('F', md5(p))
    ok = all(got.get(k) == v for k, v in exp.items())
    print(f'  {"통과 ✓" if ok else "실패 ✗"}: 기대 {len(exp)}개 중 일치 {sum(got.get(k) == v for k, v in exp.items())}개')
    for k in sorted(got): print('    ', got[k][0], k)
