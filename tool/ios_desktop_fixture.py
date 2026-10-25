"""A real Bonjour advertisement and HTTP probe for native discovery acceptance.

This is a controlled service, not a complete desktop pairing/transfer server.
"""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import threading


def fixture_identity():
    explicit = os.environ.get('LOKAL_IOS_DISCOVERY_FIXTURE')
    if explicit:
        return explicit
    run_id = os.environ.get('GITHUB_RUN_ID')
    if run_id:
        return f'lokal-ios-fixture-{run_id}-{os.environ.get("GITHUB_RUN_ATTEMPT", "1")}'
    return 'lokal-ios-local-fixture'


@contextmanager
def desktop_fixture(output: Path):
    identity = fixture_identity()

    class Probe(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/lokal-ios-discovery-probe':
                self.send_response(404)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            body = json.dumps({'id': identity, 'proto': 1}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('0.0.0.0', 0), Probe)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    publishers = []
    logs = []
    try:
        for suffix, protocol in [('valid', '1'), ('unsupported', '2')]:
            log = (output / f'ios-bonjour-{suffix}.log').open('w')
            logs.append(log)
            advertised_id = identity if protocol == '1' else identity + '-unsupported'
            process = subprocess.Popen([
                'dns-sd', '-R', f'Lokal fixture {identity.removeprefix("lokal-ios-")} {suffix}',
                '_lokal._tcp', 'local.', str(server.server_port),
                f'proto={protocol}', f'id={advertised_id}', 'name=Native fixture desktop',
            ], stdout=log, stderr=subprocess.STDOUT)
            publishers.append(process)
            if process.poll() is not None:
                raise RuntimeError('Bonjour fixture registration exited; inspect its log')
        (output / 'ios-bonjour-fixture.json').write_text(json.dumps({
            'id': identity, 'port': server.server_port,
            'scope': 'Native discovery and HTTP reachability only; no pairing or transfer acceptance',
        }, indent=2) + '\n')
        yield
    finally:
        for process in publishers:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        for log in logs:
            log.close()
