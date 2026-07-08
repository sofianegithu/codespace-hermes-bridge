"""
Cloudflare quick-tunnel launcher — no signup required, gives you a public
https://<random>.trycloudflare.com URL that forwards to localhost:PORT.

Why Cloudflare quick-tunnel and not ngrok?
  - No account needed, no authtoken
  - URLs are stable for the lifetime of the tunnel
  - Works inside Codespaces / Docker / corporate networks
  - Trade-off: URL changes on every restart (fine for a webhook receiver)
"""
from __future__ import annotations

import logging
import os
import re
import subprocess
import threading
import time
from pathlib import Path

log = logging.getLogger("tunnel")

URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")


class CloudflareTunnel:
    """Starts a `cloudflared tunnel --url http://localhost:PORT` subprocess,
    waits for the public URL to appear on stdout, and exposes it via .url."""

    def __init__(self, port: int):
        self.port = port
        self._proc: subprocess.Popen | None = None
        self.url: str | None = None
        self._log_path = Path("/tmp/cloudflared.log")
        self._ready = threading.Event()

    def start(self, timeout: float = 60.0) -> str:
        if self._proc is not None:
            return self.url or ""
        # `cloudflared` binary is preinstalled in the devcontainer
        cmd = ["cloudflared", "tunnel", "--no-autoupdate", "--url", f"http://localhost:{self.port}"]
        log.info("starting cloudflared: %s", " ".join(cmd))
        self._log_path.unlink(missing_ok=True)
        self._proc = subprocess.Popen(
            cmd,
            stdout=open(self._log_path, "w"),
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )
        # Reader thread: scan the log for the URL
        threading.Thread(target=self._wait_for_url, daemon=True).start()
        if not self._ready.wait(timeout=timeout):
            raise RuntimeError(f"cloudflared did not produce a URL in {timeout}s")
        return self.url  # type: ignore[return-value]

    def _wait_for_url(self) -> None:
        deadline = time.time() + 90
        while time.time() < deadline and self._proc and self._proc.poll() is None:
            try:
                text = self._log_path.read_text(errors="ignore")
            except FileNotFoundError:
                time.sleep(0.3)
                continue
            m = URL_RE.search(text)
            if m:
                self.url = m.group(0)
                log.info("tunnel url: %s", self.url)
                self._ready.set()
                return
            time.sleep(0.5)
        log.error("cloudflared exited without producing a URL")

    def stop(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        self._proc = None


def main() -> None:
    """CLI entry: print the URL so the caller can capture it."""
    from . import config

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    tunnel = CloudflareTunnel(config.PORT)
    url = tunnel.start()
    print(url)
    # Keep alive until killed
    try:
        tunnel._proc.wait()  # type: ignore[union-attr]
    except KeyboardInterrupt:
        tunnel.stop()


if __name__ == "__main__":
    main()
