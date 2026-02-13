import { useEffect, useRef, useState, useMemo } from "react";
import { Link } from "react-router-dom";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useEventStream } from "@/hooks/use-event-stream";
import { STATE_COLORS } from "@/lib/constants";
import { Pause, Play, Trash2 } from "lucide-react";

const EVENT_TYPE_COLORS: Record<string, string> = {
  "job.enqueued": STATE_COLORS.pending,
  "job.started": STATE_COLORS.active,
  "job.completed": STATE_COLORS.completed,
  "job.failed": STATE_COLORS.dead,
  "job.retrying": STATE_COLORS.retrying,
  "job.cancelled": STATE_COLORS.cancelled,
  "job.dead": STATE_COLORS.dead,
  "queue.paused": "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200",
  "queue.resumed": "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
};

const ALL_EVENT_TYPES = [
  "job.enqueued",
  "job.started",
  "job.completed",
  "job.failed",
  "job.retrying",
  "job.dead",
  "job.cancelled",
  "queue.paused",
  "queue.resumed",
];

export default function EventsPage() {
  const { events, paused, setPaused, clear } = useEventStream();
  const bottomRef = useRef<HTMLDivElement>(null);
  const [typeFilter, setTypeFilter] = useState<Set<string>>(new Set());

  const filtered = useMemo(() => {
    if (typeFilter.size === 0) return events;
    return events.filter((e) => typeFilter.has(e.type));
  }, [events, typeFilter]);

  useEffect(() => {
    if (!paused) {
      bottomRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [filtered.length, paused]);

  const toggleType = (t: string) => {
    setTypeFilter((prev) => {
      const next = new Set(prev);
      if (next.has(t)) next.delete(t);
      else next.add(t);
      return next;
    });
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Live Events</h1>
        <div className="flex gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => setPaused(!paused)}
          >
            {paused ? (
              <>
                <Play className="mr-1 h-3 w-3" /> Resume
              </>
            ) : (
              <>
                <Pause className="mr-1 h-3 w-3" /> Pause
              </>
            )}
          </Button>
          <Button variant="outline" size="sm" onClick={clear}>
            <Trash2 className="mr-1 h-3 w-3" /> Clear
          </Button>
        </div>
      </div>

      {/* Type filter chips */}
      <div className="flex flex-wrap gap-1.5">
        {ALL_EVENT_TYPES.map((t) => {
          const active = typeFilter.size === 0 || typeFilter.has(t);
          return (
            <Badge
              key={t}
              variant="secondary"
              className={`cursor-pointer transition-opacity ${
                active
                  ? EVENT_TYPE_COLORS[t] || ""
                  : "opacity-40 hover:opacity-70"
              }`}
              onClick={() => toggleType(t)}
            >
              {t}
            </Badge>
          );
        })}
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">
            Events
            <span className="ml-2 font-normal text-muted-foreground">
              ({filtered.length} shown)
            </span>
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <div className="max-h-[600px] overflow-auto">
            <div className="divide-y">
              {filtered.map((event, i) => (
                <div
                  key={`${event.type}-${event.job_id}-${event.created_at}-${i}`}
                  className="flex items-center gap-3 px-4 py-2 text-sm"
                >
                  <Badge
                    variant="secondary"
                    className={`text-xs ${EVENT_TYPE_COLORS[event.type] || ""}`}
                  >
                    {event.type}
                  </Badge>
                  {event.job_id && (
                    <Link
                      to={`/ui/jobs/${event.job_id}`}
                      className="font-mono text-xs text-primary hover:underline"
                    >
                      {event.job_id.slice(0, 12)}
                    </Link>
                  )}
                  {event.queue && (
                    <span className="text-xs text-muted-foreground">
                      {event.queue}
                    </span>
                  )}
                  <span className="ml-auto text-xs text-muted-foreground">
                    {new Date(event.created_at).toLocaleTimeString()}
                  </span>
                </div>
              ))}
              {filtered.length === 0 && (
                <div className="py-12 text-center text-sm text-muted-foreground">
                  {paused ? "Paused — events buffered" : "Waiting for events..."}
                </div>
              )}
            </div>
            <div ref={bottomRef} />
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
