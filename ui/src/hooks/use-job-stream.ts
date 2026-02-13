import { useEffect, useMemo, useState } from "react";

interface StreamEventPayload {
  job_id?: string;
  stream_delta?: string;
  at_ns?: number;
}

export function useJobStream(jobID: string, initialContent = "") {
  const [live, setLive] = useState(initialContent);
  const [lastAtNs, setLastAtNs] = useState(0);

  useEffect(() => {
    setLive(initialContent);
  }, [jobID, initialContent]);

  useEffect(() => {
    if (!jobID) return;
    const es = new EventSource("/api/v1/events");
    const onStream = (evt: MessageEvent) => {
      try {
        const payload = JSON.parse(evt.data) as StreamEventPayload;
        if (payload.job_id !== jobID || !payload.stream_delta) return;
        setLive((prev) => `${prev}${payload.stream_delta}`);
        if (typeof payload.at_ns === "number") {
          setLastAtNs(payload.at_ns);
        }
      } catch {
        // ignore malformed events
      }
    };
    es.addEventListener("job.stream", onStream);
    return () => {
      es.removeEventListener("job.stream", onStream);
      es.close();
    };
  }, [jobID]);

  const isStreaming = useMemo(() => {
    if (lastAtNs <= 0) return false;
    const nowNs = Date.now() * 1_000_000;
    return nowNs - lastAtNs <= 5_000_000_000;
  }, [lastAtNs, live]);

  return { content: live, isStreaming };
}
