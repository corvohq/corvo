from __future__ import annotations

from typing import Any, Callable, Dict, Optional

import requests


class CorvoError(Exception):
    pass


class CorvoClient:
    def __init__(
        self,
        base_url: str,
        timeout: float = 30.0,
        headers: Optional[Dict[str, str]] = None,
        bearer_token: str = "",
        api_key: str = "",
        api_key_header: str = "X-API-Key",
        token_provider: Optional[Callable[[], str]] = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session = requests.Session()
        self.headers = headers or {}
        self.bearer_token = bearer_token
        self.api_key = api_key
        self.api_key_header = api_key_header
        self.token_provider = token_provider

    def enqueue(self, queue: str, payload: Any, **kwargs: Any) -> Dict[str, Any]:
        body = {"queue": queue, "payload": payload}
        body.update(kwargs)
        return self._request("POST", "/api/v1/enqueue", body)

    def get_job(self, job_id: str) -> Dict[str, Any]:
        return self._request("GET", f"/api/v1/jobs/{job_id}")

    def search(self, filt: Dict[str, Any]) -> Dict[str, Any]:
        return self._request("POST", "/api/v1/jobs/search", filt)

    def bulk(self, req: Dict[str, Any]) -> Dict[str, Any]:
        return self._request("POST", "/api/v1/jobs/bulk", req)

    def bulk_status(self, bulk_id: str) -> Dict[str, Any]:
        return self._request("GET", f"/api/v1/bulk/{bulk_id}")

    def ack(self, job_id: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return self._request("POST", f"/api/v1/ack/{job_id}", body or {})

    def fetch(self, queues: list[str], worker_id: str, hostname: str = "corvo-worker", timeout: int = 30) -> Optional[Dict[str, Any]]:
        out = self._request(
            "POST",
            "/api/v1/fetch",
            {"queues": queues, "worker_id": worker_id, "hostname": hostname, "timeout": timeout},
        )
        if not out or not out.get("job_id"):
            return None
        return out

    def fail(self, job_id: str, error: str, backtrace: str = "") -> Dict[str, Any]:
        return self._request("POST", f"/api/v1/fail/{job_id}", {"error": error, "backtrace": backtrace})

    def heartbeat(self, jobs: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
        return self._request("POST", "/api/v1/heartbeat", {"jobs": jobs})

    def _request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        url = self.base_url + path
        headers = {"Content-Type": "application/json"}
        headers.update(self.headers)
        if self.api_key:
            headers[self.api_key_header or "X-API-Key"] = self.api_key
        token = self.bearer_token
        if self.token_provider is not None:
            token = self.token_provider()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        resp = self.session.request(method=method, url=url, json=body, timeout=self.timeout, headers=headers)
        if not resp.ok:
            msg = f"HTTP {resp.status_code}"
            try:
                data = resp.json()
                if isinstance(data, dict) and data.get("error"):
                    msg = str(data["error"])
            except Exception:
                pass
            raise CorvoError(msg)
        if resp.status_code == 204 or not resp.content:
            return {}
        return resp.json()
