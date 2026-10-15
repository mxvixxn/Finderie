# VMware 내부망에서만 쓰는 임시 파일 서버: GET은 windows-test 안 파일, PUT은 results/에 저장
import http.server, os, sys, threading, urllib.parse
ROOT = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(ROOT, 'results'), exist_ok=True)

class H(http.server.BaseHTTPRequestHandler):
    def _path(self):
        rel = urllib.parse.unquote(self.path.split('?')[0]).lstrip('/')
        full = os.path.normpath(os.path.join(ROOT, rel))
        if not full.startswith(ROOT + os.sep): raise PermissionError(rel)
        return rel, full
    def do_GET(self):
        rel, full = self._path()
        if rel == 'list.txt':
            names = [f'zips/{n}' for n in sorted(os.listdir(f'{ROOT}/zips'))] + [f'expected/{n}' for n in sorted(os.listdir(f'{ROOT}/expected'))]
            body = ('\n'.join(names) + '\n').encode('utf-8')
        elif rel in ('run.ps1',) or rel.startswith(('zips/', 'expected/')):
            body = open(full, 'rb').read() if os.path.isfile(full) else None
        else:
            body = None
        if body is None: self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_PUT(self):
        rel, _ = self._path()
        if not rel.startswith('upload/') or '/' in rel[7:]: self.send_error(403); return
        n = int(self.headers.get('Content-Length', 0))
        with open(os.path.join(ROOT, 'results', rel[7:]), 'wb') as f:
            while n > 0:
                b = self.rfile.read(min(n, 1 << 20)); f.write(b); n -= len(b)
        self.send_response(201); self.send_header('Content-Length', '0'); self.end_headers()
    def log_message(self, fmt, *a): sys.stderr.write('%s %s\n' % (self.client_address[0], fmt % a))

for ip in sys.argv[1:]:
    s = http.server.ThreadingHTTPServer((ip, 8765), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    print('listening', ip, flush=True)
threading.Event().wait()
