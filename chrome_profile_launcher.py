from __future__ import annotations

import argparse
import base64
import contextlib
import json
import os
import random
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import unquote, urlparse


PROXY_HELPER_HOST = "127.0.0.1"
PROXY_HELPER_CONNECT_TIMEOUT_SECONDS = 15.0
PROXY_HELPER_READY_TIMEOUT_SECONDS = 5.0
PROXY_HELPER_IDLE_TIMEOUT_SECONDS = 6 * 60 * 60
MAX_HTTP_HEADER_BYTES = 64 * 1024


def trim(value: object | None) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def load_dotenv(env_path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not env_path.is_file():
        return values

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and (
            (value.startswith('"') and value.endswith('"'))
            or (value.startswith("'") and value.endswith("'"))
        ):
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def coalesce(*values: object | None) -> str | None:
    for value in values:
        resolved = trim(value)
        if resolved is not None:
            return resolved
    return None


def parse_int(value: object | None) -> int | None:
    resolved = trim(value)
    if resolved is None:
        return None
    try:
        return int(resolved)
    except ValueError as exc:
        raise ValueError(f"Count must be an integer. Received {resolved!r}.") from exc


def parse_non_negative_int(value: object | None, name: str) -> int | None:
    resolved = trim(value)
    if resolved is None:
        return None
    try:
        parsed = int(resolved)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer. Received {resolved!r}.") from exc
    if parsed < 0:
        raise ValueError(f"{name} must be at least 0.")
    return parsed


def parse_bool(value: object | None) -> bool:
    resolved = trim(value)
    if resolved is None:
        return False
    return resolved.lower() in {"1", "true", "yes", "on"}


def parse_proxy_strategy(value: object | None) -> str:
    resolved = trim(value)
    if resolved is None:
        return "range"

    strategy = resolved.lower()
    valid_strategies = {"range", "profile", "cycle", "random"}
    if strategy not in valid_strategies:
        options = ", ".join(sorted(valid_strategies))
        raise ValueError(f"CHROME_PROXY_STRATEGY must be one of {options}. Received {resolved!r}.")
    return strategy


def looks_like_range(value: object | None) -> bool:
    resolved = trim(value)
    if resolved is None:
        return False
    if resolved.startswith("[") and resolved.endswith("]"):
        return True
    return bool(re.fullmatch(r"\d+\s*([,;-]\s*\d+)?", resolved))


def parse_profile_range(range_value: object | None, fallback_count: int | None) -> tuple[int, int]:
    resolved = trim(range_value)
    if resolved is not None:
        normalized = resolved
        if normalized.startswith("[") and normalized.endswith("]"):
            normalized = normalized[1:-1].strip()

        parts = [part.strip() for part in re.split(r"\s*[,;-]\s*", normalized) if part.strip()]
        if not 1 <= len(parts) <= 2:
            raise ValueError("CHROME_PROFILE_RANGE must contain one integer like [5] or two integers like [4,7].")

        try:
            start = int(parts[0])
            end = int(parts[1]) if len(parts) == 2 else start
        except ValueError as exc:
            raise ValueError("CHROME_PROFILE_RANGE must contain integers, for example [5] or [4,7].") from exc

        if start < 1 or end < 1:
            raise ValueError("CHROME_PROFILE_RANGE values must be at least 1.")
        if end < start:
            raise ValueError("CHROME_PROFILE_RANGE end must be greater than or equal to start.")
        return start, end

    if fallback_count is None or fallback_count < 1:
        raise ValueError("Set CHROME_PROFILE_RANGE like [5] or [4,7], or set CHROME_PROFILE_COUNT to at least 1.")

    return 1, fallback_count


def parse_urls(cli_urls: list[str] | None, env_value: object | None) -> list[str]:
    if cli_urls:
        urls = [url.strip() for url in cli_urls if trim(url)]
        if urls:
            return urls

    resolved = trim(env_value)
    if resolved is not None:
        parts = [part.strip() for part in re.split(r"[,;]", resolved) if part.strip()]
        if parts:
            return parts

    return ["https://contactout.com/", "https://outlook.com/"]


def load_proxy_strings(proxy_file: Path | None) -> list[str]:
    if proxy_file is None:
        return []
    if not proxy_file.is_file():
        raise FileNotFoundError(f"Proxy file not found: {proxy_file}")

    proxies: list[str] = []
    for raw_line in proxy_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        if line.endswith(","):
            line = line[:-1].rstrip()
        if len(line) >= 2 and (
            (line.startswith('"') and line.endswith('"'))
            or (line.startswith("'") and line.endswith("'"))
        ):
            line = line[1:-1]
        resolved = trim(line)
        if resolved is not None:
            proxies.append(resolved)

    if not proxies:
        raise ValueError(f"No proxies found in {proxy_file}. Add one proxy URL per line.")

    return proxies


def parse_proxy(proxy_value: str) -> dict[str, object]:
    parsed = urlparse(proxy_value)
    if not parsed.scheme:
        raise ValueError(f"Proxy is missing a scheme: {proxy_value!r}")
    if parsed.hostname is None:
        raise ValueError(f"Proxy is missing a host: {proxy_value!r}")
    if parsed.port is None:
        raise ValueError(f"Proxy is missing a port: {proxy_value!r}")

    username = unquote(parsed.username) if parsed.username is not None else ""
    password = unquote(parsed.password) if parsed.password is not None else ""

    return {
        "raw": proxy_value,
        "scheme": parsed.scheme,
        "host": parsed.hostname,
        "port": parsed.port,
        "username": username,
        "password": password,
        "server": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}",
    }


def build_proxy_auth_extension(profile_path: Path, profile_name: str, proxy: dict[str, object]) -> Path | None:
    username = str(proxy["username"])
    password = str(proxy["password"])
    if not username and not password:
        return None

    extension_dir = profile_path / "_managed_proxy_auth_extension"
    extension_dir.mkdir(parents=True, exist_ok=True)

    manifest = {
        "manifest_version": 3,
        "name": f"Managed Proxy Auth {profile_name}",
        "version": "1.0.0",
        "permissions": [
            "webRequest",
            "webRequestAuthProvider",
        ],
        "host_permissions": [
            "<all_urls>",
        ],
        "background": {
            "service_worker": "service-worker.js",
        },
    }

    proxy_config = {
        "host": proxy["host"],
        "port": proxy["port"],
        "username": username,
        "password": password,
    }

    service_worker = (
        f"const proxyConfig = {json.dumps(proxy_config, ensure_ascii=True)};\n"
        "const authAttempts = new Map();\n"
        "\n"
        "function clearAttempt(details) {\n"
        "  authAttempts.delete(details.requestId);\n"
        "}\n"
        "\n"
        "chrome.webRequest.onAuthRequired.addListener(\n"
        "  (details) => {\n"
        "    if (!details.isProxy) {\n"
        "      return;\n"
        "    }\n"
        "\n"
        "    if (details.challenger.host !== proxyConfig.host || details.challenger.port !== proxyConfig.port) {\n"
        "      return;\n"
        "    }\n"
        "\n"
        "    const priorAttempts = authAttempts.get(details.requestId) ?? 0;\n"
        "    if (priorAttempts >= 1) {\n"
        "      authAttempts.delete(details.requestId);\n"
        "      return { cancel: true };\n"
        "    }\n"
        "\n"
        "    authAttempts.set(details.requestId, priorAttempts + 1);\n"
        "    return {\n"
        "      authCredentials: {\n"
        "        username: proxyConfig.username,\n"
        "        password: proxyConfig.password,\n"
        "      },\n"
        "    };\n"
        "  },\n"
        "  { urls: ['<all_urls>'] },\n"
        "  ['blocking']\n"
        ");\n"
        "\n"
        "chrome.webRequest.onCompleted.addListener(clearAttempt, { urls: ['<all_urls>'] });\n"
        "chrome.webRequest.onErrorOccurred.addListener(clearAttempt, { urls: ['<all_urls>'] });\n"
    )

    (extension_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    (extension_dir / "service-worker.js").write_text(service_worker, encoding="utf-8")

    return extension_dir


def select_proxy_for_profile(
    proxies: list[dict[str, object]],
    profile_number: int,
    range_start: int,
    proxy_strategy: str,
    proxy_start_index: int,
) -> tuple[int, dict[str, object]]:
    if not proxies:
        raise ValueError("No proxies are available for selection.")

    if proxy_strategy == "range":
        proxy_index = proxy_start_index + (profile_number - range_start)
        if proxy_index >= len(proxies):
            raise ValueError(
                f"Proxy selection needs index {proxy_index}, but the proxy file only has {len(proxies)} entries. "
                "Adjust CHROME_PROXY_START_INDEX, shrink CHROME_PROFILE_RANGE, or use CHROME_PROXY_STRATEGY=cycle."
            )
    elif proxy_strategy == "profile":
        proxy_index = proxy_start_index + (profile_number - 1)
        if proxy_index >= len(proxies):
            raise ValueError(
                f"Profile {profile_number} maps to proxy index {proxy_index}, but the proxy file only has "
                f"{len(proxies)} entries. Adjust CHROME_PROXY_START_INDEX or use CHROME_PROXY_STRATEGY=cycle."
            )
    else:
        proxy_index = (proxy_start_index + (profile_number - range_start)) % len(proxies)

    return proxy_index, proxies[proxy_index]


def build_random_proxy_plan(
    proxies: list[dict[str, object]],
    profile_numbers: list[int],
    proxy_start_index: int,
    random_seed: int | None,
) -> dict[int, tuple[int, dict[str, object]]]:
    if not proxies:
        raise ValueError("No proxies are available for random selection.")
    if proxy_start_index >= len(proxies):
        raise ValueError(
            f"CHROME_PROXY_START_INDEX must be between 0 and {len(proxies) - 1} for the configured proxy file."
        )

    eligible_indices = list(range(proxy_start_index, len(proxies)))
    if not eligible_indices:
        raise ValueError("No proxies are available after CHROME_PROXY_START_INDEX.")

    generator = random.Random(random_seed)
    plan: dict[int, tuple[int, dict[str, object]]] = {}

    if len(profile_numbers) <= len(eligible_indices):
        selected_indices = generator.sample(eligible_indices, k=len(profile_numbers))
    else:
        selected_indices = [generator.choice(eligible_indices) for _ in profile_numbers]

    for profile_number, proxy_index in zip(profile_numbers, selected_indices):
        plan[profile_number] = (proxy_index, proxies[proxy_index])

    return plan


def build_proxy_authorization_value(proxy: dict[str, object]) -> str | None:
    username = str(proxy["username"])
    password = str(proxy["password"])
    if not username and not password:
        return None

    token = f"{username}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(token).decode("ascii")


def read_http_message_head(sock: socket.socket, max_bytes: int = MAX_HTTP_HEADER_BYTES) -> tuple[bytes, bytes]:
    buffer = bytearray()
    while b"\r\n\r\n" not in buffer:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buffer.extend(chunk)
        if len(buffer) > max_bytes:
            raise ValueError("HTTP header exceeds the supported size limit.")

    head, separator, rest = bytes(buffer).partition(b"\r\n\r\n")
    if not separator:
        return b"", b""
    return head + separator, rest


def parse_http_head(head: bytes) -> tuple[bytes, list[tuple[str, str]]]:
    if not head:
        return b"", []

    lines = head.split(b"\r\n")
    request_line = lines[0]
    headers: list[tuple[str, str]] = []
    for raw_line in lines[1:]:
        if not raw_line:
            continue
        name, separator, value = raw_line.partition(b":")
        if not separator:
            continue
        headers.append(
            (
                name.decode("iso-8859-1").strip(),
                value.decode("iso-8859-1").strip(),
            )
        )
    return request_line, headers


def find_header_value(headers: list[tuple[str, str]], name: str) -> str | None:
    target = name.lower()
    for header_name, header_value in headers:
        if header_name.lower() == target:
            return header_value
    return None


def build_forward_request_head(
    request_line: bytes,
    headers: list[tuple[str, str]],
    proxy_authorization: str | None,
    *,
    close_connection: bool,
) -> bytes:
    lines = [request_line]
    for header_name, header_value in headers:
        normalized = header_name.lower()
        if normalized == "proxy-authorization":
            continue
        if close_connection and normalized in {"connection", "proxy-connection"}:
            continue
        lines.append(f"{header_name}: {header_value}".encode("iso-8859-1"))

    if proxy_authorization is not None:
        lines.append(f"Proxy-Authorization: {proxy_authorization}".encode("iso-8859-1"))
    if close_connection:
        lines.append(b"Connection: close")
        lines.append(b"Proxy-Connection: close")

    return b"\r\n".join(lines) + b"\r\n\r\n"


def relay_socket_to_socket(source: socket.socket, destination: socket.socket) -> None:
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            destination.sendall(chunk)
    except OSError:
        pass
    finally:
        with contextlib.suppress(OSError):
            destination.shutdown(socket.SHUT_WR)


def relay_connect_tunnel(
    client_socket: socket.socket,
    upstream_socket: socket.socket,
    initial_upstream_bytes: bytes = b"",
) -> None:
    if initial_upstream_bytes:
        client_socket.sendall(initial_upstream_bytes)

    upstream_to_client = threading.Thread(
        target=relay_socket_to_socket,
        args=(upstream_socket, client_socket),
        daemon=True,
    )
    upstream_to_client.start()
    relay_socket_to_socket(client_socket, upstream_socket)
    upstream_to_client.join(timeout=1.0)


def find_free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((PROXY_HELPER_HOST, 0))
        return int(sock.getsockname()[1])


def wait_for_listening_port(host: str, port: int, timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.25)
            try:
                sock.connect((host, port))
                return
            except OSError:
                time.sleep(0.1)
    raise RuntimeError(f"Timed out while waiting for local proxy helper on {host}:{port}.")


class ManagedProxyForwarderHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.request.settimeout(PROXY_HELPER_CONNECT_TIMEOUT_SECONDS)
        try:
            while True:
                request_head, buffered_body = read_http_message_head(self.request)
                if not request_head:
                    return

                request_line, headers = parse_http_head(request_head)
                if not request_line:
                    return

                self.server.last_activity = time.monotonic()
                if request_line.upper().startswith(b"CONNECT "):
                    self.handle_connect(request_line, headers)
                    return
                self.handle_forward_request(request_line, headers, buffered_body)
        except Exception:
            with contextlib.suppress(OSError):
                self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")

    def connect_upstream(self) -> socket.socket:
        if self.server.upstream_scheme.lower() != "http":
            raise ValueError(
                f"Managed proxy auth currently supports upstream HTTP proxies only. "
                f"Received {self.server.upstream_scheme!r}."
            )
        return socket.create_connection(
            (self.server.upstream_host, self.server.upstream_port),
            timeout=PROXY_HELPER_CONNECT_TIMEOUT_SECONDS,
        )

    def handle_connect(self, request_line: bytes, headers: list[tuple[str, str]]) -> None:
        forward_head = build_forward_request_head(
            request_line,
            headers,
            self.server.proxy_authorization,
            close_connection=False,
        )

        try:
            with self.connect_upstream() as upstream_socket:
                upstream_socket.settimeout(PROXY_HELPER_CONNECT_TIMEOUT_SECONDS)
                upstream_socket.sendall(forward_head)
                response_head, extra_bytes = read_http_message_head(upstream_socket)
                if not response_head:
                    raise RuntimeError("Upstream proxy closed before responding to CONNECT.")

                self.request.sendall(response_head)
                status_line = response_head.split(b"\r\n", 1)[0]
                if b" 200 " not in status_line:
                    if extra_bytes:
                        self.request.sendall(extra_bytes)
                    return

                relay_connect_tunnel(self.request, upstream_socket, initial_upstream_bytes=extra_bytes)
        except Exception:
            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")

    def handle_forward_request(
        self,
        request_line: bytes,
        headers: list[tuple[str, str]],
        buffered_body: bytes,
    ) -> None:
        content_length_value = find_header_value(headers, "Content-Length")
        transfer_encoding = find_header_value(headers, "Transfer-Encoding")
        if transfer_encoding is not None and transfer_encoding.lower() == "chunked":
            raise ValueError("Chunked proxy request bodies are not supported by the managed proxy helper.")

        body = buffered_body
        expected_length = int(content_length_value) if content_length_value else 0
        while len(body) < expected_length:
            chunk = self.request.recv(min(65536, expected_length - len(body)))
            if not chunk:
                break
            body += chunk

        forward_head = build_forward_request_head(
            request_line,
            headers,
            self.server.proxy_authorization,
            close_connection=True,
        )

        with self.connect_upstream() as upstream_socket:
            upstream_socket.settimeout(PROXY_HELPER_CONNECT_TIMEOUT_SECONDS)
            upstream_socket.sendall(forward_head)
            if body:
                upstream_socket.sendall(body)

            while True:
                response_chunk = upstream_socket.recv(65536)
                if not response_chunk:
                    break
                self.request.sendall(response_chunk)


class ManagedProxyForwarderServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, config: dict[str, object]):
        host = str(config["listen_host"])
        port = int(config["listen_port"])
        super().__init__((host, port), ManagedProxyForwarderHandler)
        self.config = config
        self.upstream_host = str(config["upstream_host"])
        self.upstream_port = int(config["upstream_port"])
        self.upstream_scheme = str(config["upstream_scheme"])
        self.proxy_authorization = str(config["proxy_authorization"]) or None
        self.idle_timeout_seconds = int(config["idle_timeout_seconds"])
        self.last_activity = time.monotonic()
        self.shutdown_requested = False

    def service_actions(self) -> None:
        if self.shutdown_requested:
            return
        if time.monotonic() - self.last_activity > self.idle_timeout_seconds:
            self.shutdown_requested = True
            threading.Thread(target=self.shutdown, daemon=True).start()


def run_proxy_forwarder(config_path: Path) -> int:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    server = ManagedProxyForwarderServer(config)
    with server:
        server.serve_forever(poll_interval=0.5)
    return 0


def start_local_proxy_helper(
    script_path: Path,
    profile_path: Path,
    profile_name: str,
    proxy: dict[str, object],
) -> dict[str, object]:
    if str(proxy["scheme"]).lower() != "http":
        raise ValueError(
            "Managed proxy credentials currently support HTTP proxies only. "
            f"Received {proxy['scheme']!r} for {proxy['server']}."
        )

    local_port = find_free_loopback_port()
    config_path = profile_path / "_managed_proxy_forwarder.json"
    config = {
        "listen_host": PROXY_HELPER_HOST,
        "listen_port": local_port,
        "profile_name": profile_name,
        "upstream_scheme": str(proxy["scheme"]),
        "upstream_host": str(proxy["host"]),
        "upstream_port": int(proxy["port"]),
        "proxy_authorization": build_proxy_authorization_value(proxy) or "",
        "idle_timeout_seconds": PROXY_HELPER_IDLE_TIMEOUT_SECONDS,
    }
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

    creationflags = 0
    if os.name == "nt":
        creationflags = 0x00000008 | 0x00000200 | 0x08000000

    subprocess.Popen(
        [
            sys.executable,
            str(script_path),
            "--proxy-helper-config",
            str(config_path),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=creationflags,
    )
    wait_for_listening_port(PROXY_HELPER_HOST, local_port, PROXY_HELPER_READY_TIMEOUT_SECONDS)
    return {
        "server": f"http://{PROXY_HELPER_HOST}:{local_port}",
        "display": f"http://{PROXY_HELPER_HOST}:{local_port} -> {proxy['server']}",
        "config_path": config_path,
    }


def append_launch_log(log_file: Path | None, timestamp: str, profile_name: str, profile_path: Path, proxy_summary: str | None) -> None:
    if log_file is None:
        return

    if proxy_summary is None:
        message = f"{timestamp} | {profile_name} | direct | {profile_path}"
    else:
        message = f"{timestamp} | {profile_name} | {proxy_summary} | {profile_path}"

    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(message + "\n")


def resolve_path(base_dir: Path, raw_path: object | None) -> Path | None:
    resolved = trim(raw_path)
    if resolved is None:
        return None
    path = Path(os.path.expanduser(resolved))
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def find_chrome(preferred_path: Path | None) -> Path:
    candidates: list[Path] = []
    if preferred_path is not None:
        candidates.append(preferred_path)

    for env_name, suffix in (
        ("ProgramFiles", r"Google\Chrome\Application\chrome.exe"),
        ("ProgramFiles(x86)", r"Google\Chrome\Application\chrome.exe"),
        ("LocalAppData", r"Google\Chrome\Application\chrome.exe"),
    ):
        root = os.environ.get(env_name)
        if root:
            candidates.append(Path(root) / suffix)

    for candidate in candidates:
        if candidate.is_file():
            return candidate

    raise FileNotFoundError("Could not find chrome.exe. Set CHROME_PATH in .env or pass --chrome-path.")


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Launch isolated Chrome profiles from .env settings.")
    parser.add_argument("--proxy-helper-config", help=argparse.SUPPRESS)
    parser.add_argument("--env-path", default=".env", help="Path to the .env file. Default: .env")
    parser.add_argument("--base-name", help="Profile base name, for example Harry")
    parser.add_argument("--profile-root", help="Folder where profile directories are stored")
    parser.add_argument("--chrome-path", help="Path to chrome.exe")
    parser.add_argument("--log-file", help="Path to the launch log file.")
    parser.add_argument("--proxy-file", help="Path to a proxy list file. Use one proxy URL per line.")
    parser.add_argument("--current-proxy", type=int, help="Zero-based proxy index to reuse for every launched profile.")
    parser.add_argument(
        "--proxy-strategy",
        choices=("range", "profile", "cycle", "random"),
        help="How to map a profile range onto the proxy file when --current-proxy is not set.",
    )
    parser.add_argument(
        "--proxy-start-index",
        type=int,
        help="Zero-based index in the proxy file where range or cycle mapping should begin.",
    )
    parser.add_argument(
        "--proxy-random-seed",
        type=int,
        help="Optional seed for repeatable random proxy assignment.",
    )
    parser.add_argument("--profile-range", help="Range like [5] or [4,7]")
    parser.add_argument("--count", type=int, help="Fallback count, for example 3 -> Work1 to Work3")
    parser.add_argument("urls", nargs="*", help="Optional startup URLs")
    return parser


def main() -> int:
    parser = build_argument_parser()
    args = parser.parse_args()
    if args.proxy_helper_config:
        return run_proxy_forwarder(Path(args.proxy_helper_config))

    script_dir = Path(__file__).resolve().parent
    env_path = resolve_path(script_dir, args.env_path)
    dotenv = load_dotenv(env_path or script_dir / ".env")

    base_name = coalesce(args.base_name, os.environ.get("CHROME_PROFILE_BASE_NAME"), dotenv.get("CHROME_PROFILE_BASE_NAME"))
    profile_root = resolve_path(
        script_dir,
        coalesce(args.profile_root, os.environ.get("CHROME_PROFILE_ROOT"), dotenv.get("CHROME_PROFILE_ROOT"), "chrome-profiles"),
    )
    chrome_path = resolve_path(
        script_dir,
        coalesce(args.chrome_path, os.environ.get("CHROME_PATH"), dotenv.get("CHROME_PATH")),
    )
    log_file = resolve_path(
        script_dir,
        coalesce(args.log_file, os.environ.get("CHROME_LAUNCH_LOG_FILE"), dotenv.get("CHROME_LAUNCH_LOG_FILE"), "chrome-profile-launcher.log"),
    )
    proxy_file = resolve_path(
        script_dir,
        coalesce(args.proxy_file, os.environ.get("CHROME_PROXY_FILE"), dotenv.get("CHROME_PROXY_FILE")),
    )
    unique_profile_per_launch = parse_bool(
        coalesce(
            os.environ.get("CHROME_UNIQUE_PROFILE_PER_LAUNCH"),
            dotenv.get("CHROME_UNIQUE_PROFILE_PER_LAUNCH"),
        )
    )
    session_profile_root = resolve_path(
        script_dir,
        coalesce(
            os.environ.get("CHROME_SESSION_PROFILE_ROOT"),
            dotenv.get("CHROME_SESSION_PROFILE_ROOT"),
            "chrome-profile-sessions" if unique_profile_per_launch else None,
        ),
    )
    current_proxy_value = (
        args.current_proxy
        if args.current_proxy is not None
        else coalesce(os.environ.get("CURRENT_PROXY"), dotenv.get("CURRENT_PROXY"))
    )
    proxy_strategy = parse_proxy_strategy(
        coalesce(
            args.proxy_strategy,
            os.environ.get("CHROME_PROXY_STRATEGY"),
            dotenv.get("CHROME_PROXY_STRATEGY"),
        )
    )
    proxy_start_index = parse_non_negative_int(
        coalesce(
            args.proxy_start_index,
            os.environ.get("CHROME_PROXY_START_INDEX"),
            dotenv.get("CHROME_PROXY_START_INDEX"),
        ),
        "CHROME_PROXY_START_INDEX",
    )
    if proxy_start_index is None:
        proxy_start_index = 0
    proxy_random_seed = parse_non_negative_int(
        coalesce(
            args.proxy_random_seed,
            os.environ.get("CHROME_PROXY_RANDOM_SEED"),
            dotenv.get("CHROME_PROXY_RANDOM_SEED"),
        ),
        "CHROME_PROXY_RANDOM_SEED",
    )

    range_value = coalesce(args.profile_range, os.environ.get("CHROME_PROFILE_RANGE"), dotenv.get("CHROME_PROFILE_RANGE"))
    count_value: object | None = args.count if args.count is not None else coalesce(
        os.environ.get("CHROME_PROFILE_COUNT"),
        dotenv.get("CHROME_PROFILE_COUNT"),
    )

    if range_value is None and looks_like_range(count_value):
        range_value = count_value
        count_value = None

    proxies = [parse_proxy(proxy) for proxy in load_proxy_strings(proxy_file)]
    current_proxy_index = parse_non_negative_int(current_proxy_value, "CURRENT_PROXY")
    selected_proxy: dict[str, object] | None = None
    if current_proxy_index is not None:
        if not proxies:
            raise ValueError("CURRENT_PROXY is set but no proxy list is available. Set CHROME_PROXY_FILE first.")
        if current_proxy_index >= len(proxies):
            raise ValueError(
                f"CURRENT_PROXY must be between 0 and {len(proxies) - 1} for the configured proxy file."
            )
        selected_proxy = proxies[current_proxy_index]
    count = parse_int(count_value)

    if range_value is None and count is None and proxies and selected_proxy is None:
        start, end = 1, len(proxies)
    else:
        start, end = parse_profile_range(range_value, count)

    urls = parse_urls(args.urls, dotenv.get("CHROME_START_URLS"))

    if base_name is None:
        raise ValueError("Missing CHROME_PROFILE_BASE_NAME. Set it in .env or pass --base-name.")

    chrome_exe = find_chrome(chrome_path)
    assert profile_root is not None
    profile_root.mkdir(parents=True, exist_ok=True)
    if unique_profile_per_launch:
        assert session_profile_root is not None
        session_profile_root.mkdir(parents=True, exist_ok=True)
        launch_tag = time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
    else:
        launch_tag = ""

    if proxies and selected_proxy is None and proxy_strategy not in {"cycle", "random"} and proxy_start_index >= len(proxies):
        raise ValueError(
            f"CHROME_PROXY_START_INDEX must be between 0 and {len(proxies) - 1} for the configured proxy file."
        )

    profile_numbers = list(range(start, end + 1))
    random_proxy_plan: dict[int, tuple[int, dict[str, object]]] = {}
    if proxies and selected_proxy is None and proxy_strategy == "random":
        random_proxy_plan = build_random_proxy_plan(
            proxies=proxies,
            profile_numbers=profile_numbers,
            proxy_start_index=proxy_start_index,
            random_seed=proxy_random_seed,
        )

    for number in profile_numbers:
        profile_name = f"{base_name}{number}"
        if unique_profile_per_launch:
            assert session_profile_root is not None
            profile_path = session_profile_root / profile_name / launch_tag
        else:
            profile_path = profile_root / profile_name
        profile_path.mkdir(parents=True, exist_ok=True)

        command = [
            str(chrome_exe),
            f"--user-data-dir={profile_path}",
            "--new-window",
        ]

        proxy_summary = None
        if selected_proxy is not None:
            proxy_server = str(selected_proxy["server"])
            if build_proxy_authorization_value(selected_proxy) is not None:
                helper = start_local_proxy_helper(Path(__file__).resolve(), profile_path, profile_name, selected_proxy)
                proxy_server = str(helper["server"])
            command.append(f"--proxy-server={proxy_server}")
            proxy_summary = f"proxy[{current_proxy_index}] {selected_proxy['server']}"
        elif proxies:
            if proxy_strategy == "random":
                proxy_index, proxy = random_proxy_plan[number]
            else:
                proxy_index, proxy = select_proxy_for_profile(
                    proxies=proxies,
                    profile_number=number,
                    range_start=start,
                    proxy_strategy=proxy_strategy,
                    proxy_start_index=proxy_start_index,
                )
            proxy_server = str(proxy["server"])
            if build_proxy_authorization_value(proxy) is not None:
                helper = start_local_proxy_helper(Path(__file__).resolve(), profile_path, profile_name, proxy)
                proxy_server = str(helper["server"])
            command.append(f"--proxy-server={proxy_server}")
            proxy_summary = f"proxy[{proxy_index}] {proxy['server']}"

        command.extend(urls)
        subprocess.Popen(command)
        append_launch_log(
            log_file=log_file,
            timestamp=time.strftime("%Y-%m-%d %H:%M:%S"),
            profile_name=profile_name,
            profile_path=profile_path,
            proxy_summary=proxy_summary,
        )
        if proxy_summary is None:
            print(f"Opened {profile_name} -> {profile_path}")
        else:
            print(f"Opened {profile_name} -> {profile_path} via {proxy_summary}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
