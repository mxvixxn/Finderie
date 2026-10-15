import zipfile, hashlib, os, sys, unicodedata as u
W=sys.argv[1]; Z=f'{W}/zips'
out=os.path.join(W,'expected'); os.makedirs(out, exist_ok=True)
for zn in sorted(os.listdir(Z)):
    z=zipfile.ZipFile(os.path.join(Z,zn)); lines=[]
    for i in z.infolist():
        utf=bool(i.flag_bits & 0x800)
        raw=i.orig_filename.encode('utf-8' if utf else 'cp437')
        name=raw.decode('utf-8') if utf else (raw.decode('cp949') if zn.startswith('2_') else raw.decode('utf-8'))
        name=u.normalize('NFC',name).rstrip('/').replace('/','\\')
        if i.is_dir(): lines.append(f'D\t{name}\t-\t0'); continue
        m=hashlib.md5()
        with z.open(i) as f:
            while (b:=f.read(8<<20)): m.update(b)
        lines.append(f'F\t{name}\t{m.hexdigest()}\t{i.file_size}')
    with open(os.path.join(out, zn[:-4]+'.tsv'),'w',encoding='utf-8-sig') as f: f.write('\n'.join(lines)+'\n')
    print(f'{zn}: 항목 {len(lines)}개')
