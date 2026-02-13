import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";

export function useSSE() {
  const queryClient = useQueryClient();
  const esRef = useRef<EventSource | null>(null);

  useEffect(() => {
    const es = new EventSource("/api/v1/events");
    esRef.current = es;

    es.onmessage = (e) => {
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
      // Reconnect after 3s
      setTimeout(() => {
        esRef.current = new EventSource("/api/v1/events");
      }, 3000);
    };

    return () => {
      es.close();
    };
  }, [queryClient]);
}
