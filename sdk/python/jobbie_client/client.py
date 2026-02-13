from __future__ import annotations

from typing import Any, Dict, Optional

import requests


class JobbieError(Exception):
    pass


class JobbieClient:
    def __init__(self, base_url: str, timeout: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session = requests.Session()

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

    def _request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        url = self.base_url + path
        resp = self.session.request(method=method, url=url, json=body, timeout=self.timeout)
        if not resp.ok:
            msg = f"HTTP {resp.status_code}"
            try:
                data = resp.json()
                if isinstance(data, dict) and data.get("error"):
                    msg = str(data["error"])
            except Exception:
                pass
            raise JobbieError(msg)
        if resp.status_code == 204 or not resp.content:
            return {}
        return resp.json()
