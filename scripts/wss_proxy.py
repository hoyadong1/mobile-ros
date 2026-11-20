#!/usr/bin/env python3
"""TLS reverse proxy for rosbridge, to try the app's wss:// support the way robots are often exposed
(behind HTTPS on a path). Serves wss://<host>:PORT/PATH and forwards each WebSocket to ws://UPSTREAM.
A throwaway CA and server certificate are created in CERT_DIR on first run; trust ca.pem in the client.
   python3 scripts/wss_proxy.py [port=9443] [path=/rosbridge] [upstream=127.0.0.1:9090] [cert_dir=/tmp/wss_certs]
"""
import os
import socket
import ssl
import subprocess
import sys

from tornado import gen, httpclient, ioloop, web, websocket

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9443
PATH = sys.argv[2] if len(sys.argv) > 2 else '/rosbridge'
UPSTREAM = sys.argv[3] if len(sys.argv) > 3 else '127.0.0.1:9090'
CERT_DIR = sys.argv[4] if len(sys.argv) > 4 else '/tmp/wss_certs'


def make_certs():
    os.makedirs(CERT_DIR, exist_ok=True)
    ca_key, ca, key, crt = (os.path.join(CERT_DIR, n) for n in ('ca.key', 'ca.pem', 'server.key', 'server.pem'))
    if os.path.exists(crt):
        return crt, key
    ip = socket.gethostbyname(socket.gethostname())
    addresses = {ip, '127.0.0.1'}
    try:
        addresses.update(subprocess.check_output(['hostname', '-I'], text=True).split())
    except Exception:
        pass
    san = ','.join([f'IP:{a}' for a in sorted(addresses)] + ['DNS:localhost'])
    run = lambda *a: subprocess.run(a, check=True, capture_output=True)
    run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '30', '-subj', '/CN=Mobile ROS test CA',
        '-keyout', ca_key, '-out', ca)
    csr = os.path.join(CERT_DIR, 'server.csr')
    run('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=robot', '-keyout', key, '-out', csr)
    ext = os.path.join(CERT_DIR, 'ext.cnf')
    with open(ext, 'w') as f:
        f.write(f'subjectAltName={san}\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
    run('openssl', 'x509', '-req', '-in', csr, '-CA', ca, '-CAkey', ca_key, '-CAcreateserial', '-days', '30',
        '-extfile', ext, '-out', crt)
    print(f'certificates in {CERT_DIR} for {san}', flush=True)
    return crt, key


class Proxy(websocket.WebSocketHandler):
    upstream = None

    def check_origin(self, origin):
        return True

    @gen.coroutine
    def open(self):
        self.upstream = yield websocket.websocket_connect(
            httpclient.HTTPRequest(f'ws://{UPSTREAM}/'), on_message_callback=self.from_upstream)
        print(f'client {self.request.remote_ip} -> ws://{UPSTREAM}', flush=True)

    def from_upstream(self, message):
        if message is None:
            self.close()
        else:
            self.write_message(message)

    def on_message(self, message):
        if self.upstream is not None:
            self.upstream.write_message(message)

    def on_close(self):
        if self.upstream is not None:
            self.upstream.close()


def main():
    crt, key = make_certs()
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(crt, key)
    app = web.Application([(PATH, Proxy)])
    app.listen(PORT, ssl_options=context)
    print(f'wss proxy on port {PORT} path {PATH} -> ws://{UPSTREAM}', flush=True)
    ioloop.IOLoop.current().start()


if __name__ == '__main__':
    main()
