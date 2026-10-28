"""Synthetic host-side HTTP service for actual native transfer contracts."""

import contextlib
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
    state = {'requests': {}, 'redirectHits': 0, 'cookiesSeen': False}

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
                if source == 'truncated':
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

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', len(payload), digest
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
