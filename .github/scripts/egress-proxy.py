#!/usr/bin/env python3
"""Local CONNECT proxy with a hot-swappable upstream.

OpenCode/Bun only ever talks to 127.0.0.1:<port>. For each CONNECT the proxy
reads <state-dir>/upstream:

    direct              connect to the requested host:port
    relay:<ip>:<port>   connect to that TCP relay (provider host only)
    http:<host>:<port>  CONNECT through that HTTP proxy (provider host only)

Non-provider traffic always goes direct, so GitHub/Telegram are never routed
through a public relay.

TLS is end-to-end: this process only forwards bytes and never terminates TLS.

Control files:
    <state-dir>/upstream   one line: direct | relay:ip:port | http:host:port
    <state-dir>/epoch      integer; a change closes all live tunnels so the
                           client has to open a new CONNECT (which picks up the
                           new upstream).

Logs one line per CONNECT to stdout.
"""
import os
import socket
import sys
import threading
import time

PORT = int(os.environ.get("EGRESS_LOCAL_PORT", "8089"))
STATE_DIR = os.environ.get("EGRESS_STATE_DIR", "/tmp/egress")
UPSTREAM_FILE = os.path.join(STATE_DIR, "upstream")
EPOCH_FILE = os.path.join(STATE_DIR, "epoch")
PROVIDER_HOSTS = {
    h.strip()
    for h in os.environ.get("EGRESS_PROVIDER_HOSTS", "opencode.ai,api.opencode.ai").split(",")
    if h.strip()
}
PROVIDER_PORT = int(os.environ.get("EGRESS_PROVIDER_PORT", "443"))
IDLE_TIMEOUT = int(os.environ.get("EGRESS_IDLE_TIMEOUT", "240"))


def provider_target(host):
    h = host.lower().rstrip(".")
    return h in PROVIDER_HOSTS or h.endswith(".opencode.ai")

lock = threading.Lock()
active = []
current_epoch = 0


def read_upstream():
    try:
        with open(UPSTREAM_FILE, encoding="utf-8") as f:
            return f.readline().strip() or "direct"
    except OSError:
        return "direct"


def read_epoch():
    try:
        with open(EPOCH_FILE, encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def close_all():
    with lock:
        socks = []
        for c, u in active:
            socks.extend([c, u])
        active.clear()
    for s in socks:
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            s.close()
        except OSError:
            pass


def watch_epoch():
    global current_epoch
    while True:
        e = read_epoch()
        if e != current_epoch:
            current_epoch = e
            print(f"epoch {e}: closing live tunnels", flush=True)
            close_all()
        time.sleep(0.4)


def pipe(a, b, label):
    try:
        while True:
            try:
                data = a.recv(65536)
            except socket.timeout:
                print(f"error target={label} idle_timeout after {IDLE_TIMEOUT}s", flush=True)
                break
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def read_headers(sock):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 65536:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    if b"\r\n\r\n" in data:
        head, rest = data.split(b"\r\n\r\n", 1)
        return head + b"\r\n\r\n", rest
    return data, b""


def open_http_proxy(proxy_hp, host, port):
    ph, pp = proxy_hp.rsplit(":", 1)
    s = socket.create_connection((ph, int(pp)), timeout=15)
    req = (
        f"CONNECT {host}:{port} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Proxy-Connection: keep-alive\r\n\r\n"
    ).encode()
    s.sendall(req)
    head, rest = read_headers(s)
    first = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
    if not first.startswith("HTTP/1.1 200") and not first.startswith("HTTP/1.0 200"):
        try:
            s.close()
        except OSError:
            pass
        raise OSError(f"proxy CONNECT rejected: {first}")
    return s, rest


def handle(client):
    upstream = None
    target = "?"
    try:
        client.settimeout(20)
        head, rest = read_headers(client)
        if not head:
            client.close()
            return
        first = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        if not first.upper().startswith("CONNECT "):
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            client.close()
            return
        target = first.split()[1]
        if ":" in target:
            host, port_s = target.rsplit(":", 1)
            port = int(port_s)
        else:
            host, port = target, 443

        up = read_upstream()
        route_provider = provider_target(host) and port == PROVIDER_PORT
        extra = b""
        if up.startswith("relay:") and route_provider:
            hp = up[len("relay:"):]
            ip, rport_s = hp.rsplit(":", 1)
            upstream = socket.create_connection((ip, int(rport_s)), timeout=15)
            label = hp
        elif up.startswith("http:") and route_provider:
            hp = up[len("http:"):]
            upstream, extra = open_http_proxy(hp, host, port)
            label = hp
        else:
            upstream = socket.create_connection((host, port), timeout=15)
            label = "direct"

        print(
            f"connect {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
            f"target={target} upstream={label}",
            flush=True,
        )
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        if rest:
            upstream.sendall(rest)
        if extra:
            client.sendall(extra)
        # Only the upstream->client direction gets a stall timeout. A timeout
        # on the client->upstream thread would fire while a response is actively
        # streaming, because the client has nothing to send during that time.
        client.settimeout(None)
        upstream.settimeout(IDLE_TIMEOUT)
        with lock:
            active.append((client, upstream))
        threading.Thread(target=pipe, args=(client, upstream, target), daemon=True).start()
        pipe(upstream, client, target)
    except Exception as exc:  # noqa: BLE001
        print(f"error target={target} {exc}", flush=True)
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except OSError:
            pass
    finally:
        for s in (client, upstream):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
        with lock:
            active[:] = [(c, u) for (c, u) in active if c is not client]


def main():
    global current_epoch
    os.makedirs(STATE_DIR, exist_ok=True)
    current_epoch = read_epoch()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(256)
    print(f"proxy listening 127.0.0.1:{PORT} provider={','.join(sorted(PROVIDER_HOSTS))}:{PROVIDER_PORT}", flush=True)
    threading.Thread(target=watch_epoch, daemon=True).start()
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
