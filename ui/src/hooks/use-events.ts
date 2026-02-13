import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";

export function useSSE() {
  const queryClient = useQueryClient();
  const esRef = useRef<EventSource | null>(null);

  useEffect(() => {
    let delayMs = 3000;
    let timeoutId: ReturnType<typeof setTimeout> | null = null;

    function connect() {
      const es = new EventSource("/api/v1/events");
      esRef.current = es;

      es.onmessage = (e) => {
        // Reset backoff on successful message.
        delayMs = 3000;
        try {
          const data = JSON.parse(e.data);
          const type = data.type as string;

          if (type?.startsWith("job.")) {
            queryClient.invalidateQueries({ queryKey: ["search"] });
            queryClient.invalidateQueries({ queryKey: ["queues"] });
            if (data.job_id) {
              queryClient.invalidateQueries({ queryKey: ["job", data.job_id] });
            }
          }
          if (type?.startsWith("queue.")) {
            queryClient.invalidateQueries({ queryKey: ["queues"] });
          }
        } catch {
          // ignore parse errors
        }
      };

      es.onerror = () => {
        es.close();
        timeoutId = setTimeout(() => {
          connect();
        }, delayMs);
        // Exponential backoff: 3s, 6s, 12s, 24s, max 30s.
        delayMs = Math.min(delayMs * 2, 30000);
      };
    }

    connect();

    return () => {
      if (timeoutId) clearTimeout(timeoutId);
      esRef.current?.close();
    };
  }, [queryClient]);
}
