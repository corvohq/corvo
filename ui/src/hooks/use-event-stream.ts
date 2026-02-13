import { useState, useEffect, useRef, useCallback } from "react";
import type { Event } from "@/lib/types";

const MAX_EVENTS = 500;

export function useEventStream() {
  const [events, setEvents] = useState<Event[]>([]);
  const [paused, setPaused] = useState(false);
  const pausedRef = useRef(paused);
  pausedRef.current = paused;
  const bufferRef = useRef<Event[]>([]);

  useEffect(() => {
    let delayMs = 3000;
    let timeoutId: ReturnType<typeof setTimeout> | null = null;

    function connect() {
      const es = new EventSource("/api/v1/events");

      es.onmessage = (msg) => {
        delayMs = 3000;
        try {
          const data = JSON.parse(msg.data) as Event;
          if (!data.type) return;

          if (pausedRef.current) {
            bufferRef.current = [...bufferRef.current, data].slice(-MAX_EVENTS);
          } else {
            setEvents((prev) => [...prev, data].slice(-MAX_EVENTS));
          }
        } catch {
          // ignore
        }
      };

      es.onerror = () => {
        es.close();
        timeoutId = setTimeout(connect, delayMs);
        delayMs = Math.min(delayMs * 2, 30000);
      };

      return es;
    }

    const es = connect();

    return () => {
      if (timeoutId) clearTimeout(timeoutId);
      es.close();
    };
  }, []);

  // When un-pausing, flush buffer
  useEffect(() => {
    if (!paused && bufferRef.current.length > 0) {
      setEvents((prev) => [...prev, ...bufferRef.current].slice(-MAX_EVENTS));
      bufferRef.current = [];
    }
  }, [paused]);

  const clear = useCallback(() => {
    setEvents([]);
    bufferRef.current = [];
  }, []);

  return { events, paused, setPaused, clear };
}
