"""Synthetic host-side HTTP service for actual native transfer contracts."""

import contextlib
import base64
import hashlib
import http.server
import io
import json
import math
import struct
import threading
import time
import urllib.parse
import wave


def audio_bytes():
    output = io.BytesIO()
    with wave.open(output, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b''.join(struct.pack('<h', int(1200 * math.sin(i * 2 * math.pi * 330 / 16000)))
                                   for i in range(32000)))
    return output.getvalue()


@contextlib.contextmanager
def serve_fixture():
    payload = audio_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    lock = threading.Lock()
    slow_upload_reply = threading.Event()
    slow_match_reply = threading.Event()
    storage_reply = threading.Event()
    state = {'requests': {}, 'redirectHits': 0, 'cookiesSeen': False,
             'uploadRequests': {}, 'uploadHashes': {}, 'uploadMetadataValid': True, 'uploadLeakHits': 0,
             'matchRequests': 0, 'matchMode': 'positive', 'matchQueryValid': True, 'matchLeakHits': 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def respond(self, code, body=b'', **headers):
            self.send_response(code)
            self.send_header('Content-Length', str(len(body)))
            for key, value in headers.items():
                self.send_header(key.replace('_', '-'), value)
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self):
            if self.path == '/__hold_storage':
                storage_reply.clear()
                self.respond(200)
                return
            if self.path == '/__release_storage':
                storage_reply.set()
                self.respond(200)
                return
            if self.path.startswith('/__match_mode?'):
                mode = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)['mode'][0]
                with lock:
                    state['matchMode'] = mode
                if mode == 'slow':
                    slow_match_reply.clear()
                self.respond(200)
                return
            if self.path == '/__release_match':
                slow_match_reply.set()
                self.respond(200)
                return
            if self.path == '/__release_upload':
                slow_upload_reply.set()
                self.respond(200)
                return
            if self.path == '/__upload_payload':
                self.respond(200, payload)
                return
            if self.path == '/__state':
                with lock:
                    body = json.dumps(state).encode()
                self.respond(200, body, Content_Type='application/json')
                return
            if self.path == '/leak-destination':
                with lock:
                    state['redirectHits'] += 1
                self.respond(200, payload)
                return
            prefix = '/api/remote/files/'
            if not self.path.startswith(prefix):
                self.respond(404)
                return
            source = urllib.parse.unquote(self.path[len(prefix):])
            with lock:
                state['requests'][source] = state['requests'].get(source, 0) + 1
                state['cookiesSeen'] |= self.headers.get('Cookie') is not None
            if self.headers.get('x-remote-token') != 'transfer-fixture-token' or source == 'unauthorized':
                self.respond(401)
                return
            if source == 'redirect':
                self.respond(302, b'redirect', Location='/leak-destination')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('x-content-sha256', '0' * 64 if source == 'bad-checksum' else digest)
            self.send_header('Set-Cookie', 'fixture_cookie=unexpected; Path=/')
            self.end_headers()
            try:
                if source.startswith('storage-download-'):
                    storage_reply.wait(timeout=10)
                    self.wfile.write(payload)
                    self.wfile.flush()
                elif source == 'truncated':
                    self.wfile.write(payload[:len(payload) // 2])
                    self.wfile.flush()
                    self.close_connection = True
                elif source == 'slow':
                    for offset in range(0, len(payload), 1024):
                        self.wfile.write(payload[offset:offset + 1024])
                        self.wfile.flush()
                        time.sleep(.025)
                else:
                    self.wfile.write(payload)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 1024 * 1024:
                self.close_connection = True
                self.respond(413)
                return
            body = self.rfile.read(size)
            if self.path == '/match-leak':
                with lock:
                    state['matchLeakHits'] += 1
                self.respond(200)
                return
            if self.path == '/api/remote/files/match':
                try:
                    query = json.loads(body)
                    valid = (query == {'items': [{'size': len(payload), 'sha256': digest}]}
                             and self.headers.get('Content-Type') == 'application/json'
                             and self.headers.get('x-link-metadata') is None
                             and self.headers.get('x-remote-token') == 'transfer-fixture-token')
                except ValueError:
                    valid = False
                with lock:
                    state['matchRequests'] += 1
                    state['matchQueryValid'] &= valid
                    state['cookiesSeen'] |= self.headers.get('Cookie') is not None
                    mode = state['matchMode']
                try:
                    if not valid or mode == 'unauthorized':
                        self.respond(401, b'{}', Content_Type='application/json')
                    elif mode == 'redirect':
                        self.respond(307, b'{}', Location='/match-leak', Content_Type='application/json')
                    elif mode == 'large':
                        self.respond(200, b'x' * 20000, Content_Type='application/json')
                    elif mode == 'chunked-large':
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Transfer-Encoding', 'chunked')
                        self.end_headers()
                        for _ in range(3):
                            self.wfile.write(b'2000\r\n' + b'x' * 8192 + b'\r\n')
                            self.wfile.flush()
                        self.wfile.write(b'0\r\n\r\n')
                    elif mode == 'malformed':
                        self.respond(200, b'{"matches":false}', Content_Type='application/json')
                    else:
                        if mode == 'slow':
                            slow_match_reply.wait(timeout=10)
                        match = {'index': 1 if mode == 'wrong-index' else 0,
                                 'trackId': 'https://invalid/?token=x' if mode == 'url-id' else 'matched-original'}
                        matches = [] if mode == 'none' else [match, match] if mode == 'duplicate' else [match]
                        self.respond(200, json.dumps({'matches': matches}).encode(), Content_Type='application/json',
                                     Set_Cookie='match_cookie=unexpected; Path=/')
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            if self.path == '/upload-leak':
                with lock:
                    state['uploadLeakHits'] += 1
                self.respond(200)
                return
            if self.path != '/api/remote/files':
                self.respond(404)
                return
            try:
                header = self.headers.get('x-link-metadata', '')
                metadata = json.loads(base64.urlsafe_b64decode(header + '=' * (-len(header) % 4)))
                mode = metadata['title']
            except (ValueError, KeyError):
                self.respond(400)
                return
            actual = hashlib.sha256(body).hexdigest()
            with lock:
                state['uploadRequests'][mode] = state['uploadRequests'].get(mode, 0) + 1
                state['uploadHashes'][mode] = actual
                state['cookiesSeen'] |= self.headers.get('Cookie') is not None
                state['uploadMetadataValid'] &= (
                    metadata.get('sha256') == digest and actual == digest and body == payload
                    and metadata.get('extension') == 'wav'
                    and metadata.get('artist') == 'Native fixture — Café'
                    and self.headers.get('Content-Type') == 'application/octet-stream')
            try:
                if self.headers.get('x-remote-token') != 'transfer-fixture-token' or mode == 'upload-unauthorized':
                    self.respond(401, b'{}', Content_Type='application/json')
                elif mode == 'upload-lost':
                    # The peer committed the body; only its response is lost.
                    self.close_connection = True
                elif mode == 'upload-redirect':
                    self.respond(307, b'{}', Location='/upload-leak', Content_Type='application/json')
                elif mode == 'upload-large':
                    self.respond(200, b'x' * (20 * 1024), Content_Type='application/json')
                elif mode == 'upload-large-chunked':
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Transfer-Encoding', 'chunked')
                    self.end_headers()
                    for _ in range(3):
                        chunk = b'x' * 8192
                        self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
                        self.wfile.flush()
                    self.wfile.write(b'0\r\n\r\n')
                elif mode == 'upload-malformed':
                    self.respond(200, b'{"ok":true}', Content_Type='application/json')
                elif mode == 'upload-html':
                    self.respond(200, b'<html>not a receipt</html>', Content_Type='text/html')
                else:
                    if mode == 'upload-slow':
                        slow_upload_reply.wait(timeout=10)
                    if mode.startswith('storage-upload-'):
                        storage_reply.wait(timeout=10)
                    receipt = {'ok': True, 'trackId': 'desktop-' + mode}
                    if mode == 'upload-present':
                        receipt['alreadyPresent'] = True
                    else:
                        receipt['file_hash'] = '0' * 64 if mode == 'upload-bad-hash' else actual
                    self.respond(200, json.dumps(receipt).encode(), Content_Type='application/json',
                                 Set_Cookie='upload_fixture_cookie=unexpected; Path=/')
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', len(payload), digest
    finally:
        slow_upload_reply.set()
        slow_match_reply.set()
        storage_reply.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
