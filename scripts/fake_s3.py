#!/usr/bin/env python3
# iOS 端到端测试用的假 S3（path-style，只监听 127.0.0.1，只用标准库）。im-server 的 objstore 客户端、App（模拟器和 Mac 共用网络，
# 直接访问 127.0.0.1）的预签名 PUT 和 GET 都打到这里。来源：tianting-android/scripts/fake_s3.py（原样，CORS 部分 iOS 用不到），
# 测试控制接口 /__ctl（只影响带 X-Amz-Signature 查询串的预签名请求，不影响 im-server 自己的请求）：
#   put_delay_ms=N  预签名 PUT 读完请求体后等 N 毫秒再回（上传中取消、上传中杀 App）
#   fail_puts=N     接下来 N 个预签名 PUT 不回响应直接断开（弱网、断网）
#   get_chunk_ms=N  预签名 GET 每 16 KiB 等 N 毫秒（下载到一半）
#   cut_gets=N      正在慢速传的预签名 GET 接下来 N 个直接断开连接（下载到一半断网）
#   reset=1         清掉上面这些设置和计数
# 和 /__stats（预签名 GET、PUT 的次数，按键的最后一段 original / thumb 分开）、/__list、/__raw。没有签名校验（签名在
# tianting-server 的 objstore 测试里验）。
# 用法：python3 -I fake_s3.py --port 18183
# 不打印请求（地址里有签名）。SIGTERM 时退出；加 --watch-stdin 时 stdin 关闭也退出。
import argparse
import hashlib
import json
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

objects = {}  # (bucket, key) -> (body, content_type, etag)
lock = threading.Lock()
ORIGINS = set()
ctl = {'put_delay_ms': 0, 'fail_puts': 0, 'get_chunk_ms': 0, 'cut_gets': 0}
stats = {'puts': 0, 'gets': {}}


def presigned(query):
    return 'X-Amz-Signature' in query


def split(path):
    parts = unquote(path).lstrip('/').split('/', 1)
    return parts[0], (parts[1] if len(parts) > 1 else '')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):  # 不打印：查询串里有签名
        pass

    def cors(self):
        origin = self.headers.get('Origin')
        if origin and origin in ORIGINS:
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Vary', 'Origin')
            self.send_header('Access-Control-Expose-Headers', 'ETag, Content-Type, Content-Disposition')

    def reply(self, status, body=b'', headers=None):
        self.send_response(status)
        self.cors()
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def error(self, status, code):
        self.reply(status, f'<Error><Code>{code}</Code></Error>'.encode(), {'Content-Type': 'application/xml'})

    def do_OPTIONS(self):
        # CORS 预检（PRD-chat 第 13.2 节：存储 CORS 允许上传头）。不认识的源不给 Allow-Origin，浏览器就拒绝。
        self.send_response(204)
        self.cors()
        if self.headers.get('Origin') in ORIGINS:
            self.send_header('Access-Control-Allow-Methods', 'GET, PUT, HEAD')
            self.send_header('Access-Control-Allow-Headers', self.headers.get('Access-Control-Request-Headers') or '')
            self.send_header('Access-Control-Max-Age', '600')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_PUT(self):
        u = urlsplit(self.path)
        bucket, key = split(u.path)
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else b''
        src = self.headers.get('x-amz-copy-source')
        if presigned(u.query) and not src:
            with lock:
                stats['puts'] += 1
                fail = ctl['fail_puts'] > 0
                if fail:
                    ctl['fail_puts'] -= 1
                delay = ctl['put_delay_ms']
            if fail:
                self.close_connection = True
                self.connection.close()
                return
            if delay:
                time.sleep(delay / 1000)
        with lock:
            if src:
                sb, sk = split(src)
                cur = objects.get((sb, sk))
                if cur is None:
                    return self.error(404, 'NoSuchKey')
                want = self.headers.get('x-amz-copy-source-if-match')
                if want and want != cur[2]:
                    return self.error(412, 'PreconditionFailed')
                ctype = self.headers.get('Content-Type') or cur[1]
                etag = '"' + hashlib.md5(cur[0] + b'copy').hexdigest() + '"'
                objects[(bucket, key)] = (cur[0], ctype, etag)
                xml = f'<CopyObjectResult><ETag>{escape(etag)}</ETag></CopyObjectResult>'.encode()
                return self.reply(200, xml, {'Content-Type': 'application/xml'})
            etag = '"' + hashlib.md5(body).hexdigest() + '"'
            objects[(bucket, key)] = (body, self.headers.get('Content-Type') or 'application/octet-stream', etag)
        self.reply(200, b'', {'ETag': etag})

    def do_HEAD(self):
        bucket, key = split(urlsplit(self.path).path)
        with lock:
            cur = objects.get((bucket, key))
        if cur is None:
            return self.reply(404)
        self.send_response(200)
        self.cors()
        self.send_header('Content-Length', str(len(cur[0])))
        self.send_header('ETag', cur[2])
        self.send_header('Content-Type', cur[1])
        self.end_headers()

    def do_GET(self):
        u = urlsplit(self.path)
        q = parse_qs(u.query)
        if u.path == '/__health':
            return self.reply(200, b'ok')
        if u.path == '/__ctl':
            with lock:
                if q.get('reset'):
                    ctl.update({'put_delay_ms': 0, 'fail_puts': 0, 'get_chunk_ms': 0, 'cut_gets': 0})
                    stats['puts'] = 0
                    stats['gets'] = {}
                for k in ctl:
                    if k in q:
                        ctl[k] = int(q[k][0])
                out = dict(ctl)
            return self.reply(200, json.dumps(out).encode(), {'Content-Type': 'application/json'})
        if u.path == '/__stats':
            with lock:
                out = json.dumps(stats)
            return self.reply(200, out.encode(), {'Content-Type': 'application/json'})
        if u.path == '/__list':
            # 测试用：某个前缀下的对象（键、大小、SHA-256、类型）。键是服务端生成的随机值，不含文件名。
            prefix = q.get('prefix', [''])[0]
            bucket = q.get('bucket', ['chat'])[0]
            with lock:
                items = [
                    {'key': k, 'size': len(v[0]), 'sha256': hashlib.sha256(v[0]).hexdigest(), 'type': v[1]}
                    for (b, k), v in sorted(objects.items())
                    if b == bucket and k.startswith(prefix)
                ]
            return self.reply(200, json.dumps(items).encode(), {'Content-Type': 'application/json'})
        if u.path == '/__raw':
            with lock:
                cur = objects.get((q.get('bucket', ['chat'])[0], q.get('key', [''])[0]))
            if cur is None:
                return self.error(404, 'NoSuchKey')
            return self.reply(200, cur[0], {'Content-Type': 'application/octet-stream'})
        bucket, key = split(u.path)
        if not key and 'list-type' in q:
            prefix = q.get('prefix', [''])[0]
            with lock:
                keys = sorted(k for (b, k) in objects if b == bucket and k.startswith(prefix))
            items = ''.join(f'<Contents><Key>{escape(k)}</Key></Contents>' for k in keys)
            xml = f'<ListBucketResult><IsTruncated>false</IsTruncated>{items}</ListBucketResult>'.encode()
            return self.reply(200, xml, {'Content-Type': 'application/xml'})
        with lock:
            cur = objects.get((bucket, key))
        if cur is None:
            return self.error(404, 'NoSuchKey')
        want = self.headers.get('If-Match')
        if want and want != cur[2]:
            return self.error(412, 'PreconditionFailed')
        body = cur[0]
        status = 200
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            a, _, b = rng[6:].partition('-')
            start = int(a or 0)
            end = min(int(b) if b else len(body) - 1, len(body) - 1)
            body = body[start:end + 1]
            status = 206
        headers = {'ETag': cur[2], 'Content-Type': q.get('response-content-type', [cur[1]])[0]}
        if 'response-content-disposition' in q:
            headers['Content-Disposition'] = q['response-content-disposition'][0]
        chunk_ms = 0
        if presigned(u.query):
            variant = key.rsplit('/', 1)[-1]
            with lock:
                stats['gets'][variant] = stats['gets'].get(variant, 0) + 1
                chunk_ms = ctl['get_chunk_ms']
        if not chunk_ms:
            return self.reply(status, body, headers)
        # 慢速下载：一块一块写，客户端断开时停下。
        self.send_response(status)
        self.cors()
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            for i in range(0, len(body), 16384):
                with lock:
                    cut = ctl['cut_gets'] > 0
                    if cut:
                        ctl['cut_gets'] -= 1
                if cut:
                    self.close_connection = True
                    self.connection.close()
                    return
                self.wfile.write(body[i:i + 16384])
                self.wfile.flush()
                time.sleep(chunk_ms / 1000)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def do_DELETE(self):
        bucket, key = split(urlsplit(self.path).path)
        with lock:
            objects.pop((bucket, key), None)
        self.reply(204)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=0)
    ap.add_argument('--origins', default='')
    ap.add_argument('--watch-stdin', action='store_true', help='stdin 关闭时退出（父进程用管道启动时）')
    args = ap.parse_args()
    ORIGINS.update(o for o in args.origins.split(',') if o)
    srv = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    srv.daemon_threads = True
    print(f'port {srv.server_address[1]}', flush=True)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown, daemon=True).start())
    if args.watch_stdin:
        # 父进程退出（stdin 关闭）时自己退出，不留下进程。
        threading.Thread(target=lambda: (sys.stdin.read(), srv.shutdown()), daemon=True).start()
    srv.serve_forever()


if __name__ == '__main__':
    main()
