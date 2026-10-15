import os, sys
G=sys.argv[1]
pat=b''.join(f'Zip64 시험 줄 {i:05d}\n'.encode() for i in range(700))[:16384]
with open(f'{G}/4.5GB 대용량 파일.bin','wb') as f:
    blk=pat*64
    for _ in range(4608): f.write(blk)
for d in range(70):
    os.makedirs(f'{G}/칠만개/폴더{d:02d}', exist_ok=True)
    for i in range(1000):
        with open(f'{G}/칠만개/폴더{d:02d}/파일{i:04d}.txt','w') as f: f.write(f'{d}-{i} 안녕\n')
