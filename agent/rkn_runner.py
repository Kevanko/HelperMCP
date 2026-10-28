"""Run the pinned upstream checker without changing the machine's network state."""
import contextlib
import io
import ipaddress
import json
import os
import socket
import ssl  # Load SSLSocket before substituting the socket constructor.
import struct
import sys
import time


def configure_sockets(index, source, resolvers=()):
    original = socket.socket
    original_lookup = socket.getaddrinfo
    observations = {}

    class BoundSocket(original):
        def __init__(self, family=socket.AF_INET, type=socket.SOCK_STREAM,
                     proto=0, fileno=None):
            super().__init__(family, type, proto, fileno)
            if fileno is not None:
                return  # TLS owns an already-bound connected socket; never rebind it.
            try:
                if index and family == socket.AF_INET:
                    self.setsockopt(socket.IPPROTO_IP, 31, struct.pack("!I", index))
                    self.bind((source, 0))
                elif index and family == socket.AF_INET6:
                    raise OSError("IPv6 excluded from this adapter-bound IPv4 test")
            except BaseException:
                self.close()
                raise

        def connect(self, address):
            if index and self.family == socket.AF_INET:
                ip = ipaddress.ip_address(address[0])
                if ip in ipaddress.ip_network("198.18.0.0/15"):
                    raise OSError("Fake-IP cannot be used as a physical baseline")
            return super().connect(address)

        def connect_ex(self, address):
            try:
                self.connect(address)
                return 0
            except OSError as exc:
                return exc.errno or 10065

    socket.socket = BoundSocket
    if index:
        def skip_name(data, offset):
            for _ in range(128):
                size = data[offset]
                offset += 1
                if not size:
                    return offset
                if size & 0xC0 == 0xC0:
                    return offset + 1
                if size > 63:
                    raise ValueError("Invalid DNS label")
                offset += size
            raise ValueError("Invalid DNS name")

        def resolve(host):
            prior = observations.get(host)
            if prior and time.monotonic() - prior["at"] < 30:
                return prior["ips"]
            for server in dict.fromkeys(resolvers):
                if ipaddress.ip_address(server) in ipaddress.ip_network("198.18.0.0/15"):
                    continue
                try:
                    ident = os.urandom(2)
                    query = ident + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                    for label in host.rstrip(".").encode("idna").split(b"."):
                        if not 0 < len(label) <= 63:
                            raise ValueError("Invalid hostname")
                        query += bytes([len(label)]) + label
                    query += b"\x00\x00\x01\x00\x01"
                    with BoundSocket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                        sock.settimeout(1)
                        sock.connect((server, 53))
                        sock.send(query)
                        data = sock.recv(4096)
                    if len(data) < 12 or data[:2] != ident or not data[2] & 128 or data[2] & 2 or data[3] & 15:
                        continue
                    offset = 12
                    for _ in range(struct.unpack_from("!H", data, 4)[0]):
                        offset = skip_name(data, offset) + 4
                    ips = []
                    for _ in range(struct.unpack_from("!H", data, 6)[0]):
                        offset = skip_name(data, offset)
                        kind, cls, _, length = struct.unpack_from("!HHIH", data, offset)
                        offset += 10
                        if kind == 1 and cls == 1 and length == 4:
                            ip = socket.inet_ntoa(data[offset:offset + length])
                            if ipaddress.ip_address(ip) not in ipaddress.ip_network("198.18.0.0/15"):
                                ips.append(ip)
                        offset += length
                    if ips:
                        observations[host] = {"server": server, "ips": ips, "at": time.monotonic()}
                        return ips
                except (OSError, ValueError, IndexError, struct.error):
                    continue
            raise socket.gaierror(socket.EAI_NONAME, "No real IPv4 answer from adapter-bound DNS")

        def lookup(host, port, family=0, type=0, proto=0, flags=0):
            if isinstance(host, bytes):
                host = host.decode("ascii")
            try:
                ipaddress.ip_address(host)
                ips = [host]
            except ValueError:
                ips = resolve(host)
            result = []
            for ip in ips:
                result.extend(original_lookup(ip, port, socket.AF_INET, type, proto, flags | socket.AI_NUMERICHOST))
            return result
        socket.getaddrinfo = lookup
    return observations


def main():
    with open(sys.argv[1], encoding="utf-8-sig") as file:
        config = json.load(file)
    # Do not silently inherit a proxy and call it Ethernet.
    for key in list(os.environ):
        if key.lower() in {"http_proxy", "https_proxy", "all_proxy", "no_proxy"}:
            del os.environ[key]
    index = int(config["interface_index"])
    observations = configure_sockets(index, config["source"], config.get("resolvers", ["1.1.1.1", "8.8.8.8"]))
    import requests
    init = requests.Session.__init__
    def isolated_session(self, *args, **kwargs):
        init(self, *args, **kwargs)
        self.trust_env = False
    requests.Session.__init__ = isolated_session
    from rkn_checker.cli import main as check
    args = ["--json", "--no-self-info", "--timeout", str(config["timeout"]),
            "--workers", str(config["workers"])]
    for url in config["urls"]:
        args += ["--url", url]
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        code = check(args)
    # Nonzero classification exits may still contain a complete valid report.
    report = json.loads(output.getvalue())
    if not config.get("detail"):
        report = {key: [
            {field: row.get(field) for field in (
                "name", "verdict", "confidence", "sys_ips", "doh_ips", "tcp_time_ms",
                "tls_time_ms", "status_code", "plt_ms", "dns_error", "tcp_error", "tls_error", "http_error", "notes"
            ) if row.get(field) is not None}
            for row in value
        ] for key, value in report.items() if isinstance(value, list)}
    print(json.dumps({
        "checker": "rkn-block-checker==0.6.0", "checker_exit": code,
        "interface_index": index, "source": config["source"],
        "scope": "IPv4 sockets bound to adapter" if index else "current default route (may use TUN)",
        "dns_mode": "adapter-bound UDP resolver (replaces system DNS inside this child only)" if index else "system DNS",
        "dns_observations": {host: {k: v for k, v in row.items() if k != "at"} for host, row in observations.items()},
        "limitations": [
            "Adapter DNS may fall back to configured public resolvers; inspect dns_observations.",
            "WinDivert/WFP/zapret can still affect these sockets; clean access is unproven.",
            "A block classification is evidence to investigate, not proof of its operator or cause.",
            "Upstream TCP/TLS probes use port 443 even for custom URLs; HTTP may use the URL port.",
        ], "report": report,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
