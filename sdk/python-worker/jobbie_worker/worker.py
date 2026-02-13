from __future__ import annotations

import signal
import socket
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, Optional

from jobbie_client import JobbieClient

Handler = Callable[[Dict[str, Any], "JobContext"], None]


@dataclass
class WorkerConfig:
    queues: list[str]
    worker_id: str
    hostname: str = socket.gethostname()
    concurrency: int = 10
    shutdown_timeout_s: float = 30.0


class JobContext:
    def __init__(self, worker: "JobbieWorker", job_id: str) -> None:
        self._worker = worker
        self._job_id = job_id

    def is_cancelled(self) -> bool:
        with self._worker._mu:
            return self._worker._active.get(self._job_id, {}).get("cancelled", False)

    def checkpoint(self, data: Dict[str, Any]) -> None:
        self._worker.client.heartbeat({self._job_id: {"checkpoint": data}})

    def progress(self, current: int, total: int, message: str) -> None:
        self._worker.client.heartbeat(
            {self._job_id: {"progress": {"current": current, "total": total, "message": message}}}
        )


class JobbieWorker:
    def __init__(self, client: JobbieClient, cfg: WorkerConfig) -> None:
        self.client = client
        self.cfg = cfg
        self._handlers: Dict[str, Handler] = {}
        self._active: Dict[str, Dict[str, Any]] = {}
        self._mu = threading.Lock()
        self._stop = threading.Event()

    def register(self, queue: str, handler: Handler) -> None:
        self._handlers[queue] = handler

    def start(self) -> None:
        prev_int = signal.signal(signal.SIGINT, self._on_signal)
        prev_term = signal.signal(signal.SIGTERM, self._on_signal)
        try:
            hb = threading.Thread(target=self._heartbeat_loop, daemon=True)
            hb.start()
            workers = [threading.Thread(target=self._fetch_loop, daemon=True) for _ in range(self.cfg.concurrency)]
            for t in workers:
                t.start()
            for t in workers:
                t.join()
        finally:
            signal.signal(signal.SIGINT, prev_int)
            signal.signal(signal.SIGTERM, prev_term)

    def stop(self) -> None:
        self._stop.set()
        deadline = time.time() + self.cfg.shutdown_timeout_s
        while time.time() < deadline:
            with self._mu:
                if not self._active:
                    return
            time.sleep(0.1)

        with self._mu:
            remaining = list(self._active.keys())
        for job_id in remaining:
            try:
                self.client.fail(job_id, "worker_shutdown")
            except Exception:
                pass

    def _on_signal(self, signum: int, frame: Optional[object]) -> None:
        self.stop()

    def _fetch_loop(self) -> None:
        while not self._stop.is_set():
            try:
                job = self.client.fetch(self.cfg.queues, self.cfg.worker_id, self.cfg.hostname, timeout=30)
                if not job:
                    continue
                job_id = str(job["job_id"])
                queue = str(job["queue"])

                handler = self._handlers.get(queue)
                if handler is None:
                    self.client.ack(job_id, {})
                    continue

                with self._mu:
                    self._active[job_id] = {"cancelled": False}

                ctx = JobContext(self, job_id)
                try:
                    handler(job, ctx)
                    self.client.ack(job_id, {})
                except Exception as exc:
                    self.client.fail(job_id, str(exc))
                finally:
                    with self._mu:
                        self._active.pop(job_id, None)
            except Exception:
                time.sleep(1.0)

    def _heartbeat_loop(self) -> None:
        while not self._stop.is_set():
            time.sleep(15.0)
            if self._stop.is_set():
                return
            with self._mu:
                active = list(self._active.keys())
            if not active:
                continue
            jobs = {job_id: {} for job_id in active}
            try:
                result = self.client.heartbeat(jobs)
                statuses = result.get("jobs", {}) if isinstance(result, dict) else {}
                if isinstance(statuses, dict):
                    for job_id, state in statuses.items():
                        if isinstance(state, dict) and state.get("status") == "cancel":
                            with self._mu:
                                if job_id in self._active:
                                    self._active[job_id]["cancelled"] = True
            except Exception:
                pass
