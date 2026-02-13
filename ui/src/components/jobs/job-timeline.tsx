import type { Job } from "@/lib/types";
import { timeAgo } from "@/lib/utils";
import { STATE_DOT_COLORS } from "@/lib/constants";
import { cn } from "@/lib/utils";

interface TimelineEvent {
  label: string;
  time: string;
  state: string;
  detail?: string;
}

function buildTimeline(job: Job): TimelineEvent[] {
  const events: TimelineEvent[] = [];

  events.push({
    label: "Enqueued",
    time: job.created_at,
    state: "pending",
  });

  if (job.scheduled_at) {
    events.push({
      label: "Scheduled",
      time: job.scheduled_at,
      state: "scheduled",
    });
  }

  if (job.errors) {
    for (const err of job.errors) {
      events.push({
        label: `Attempt ${err.attempt} failed`,
        time: err.created_at,
        state: "dead",
        detail: err.error,
      });
    }
  }

  if (job.started_at) {
    events.push({
      label: `Started (attempt ${job.attempt})`,
      time: job.started_at,
      state: "active",
      detail: job.worker_id ? `Worker: ${job.worker_id}` : undefined,
    });
  }

  if (job.completed_at) {
    events.push({
      label: "Completed",
      time: job.completed_at,
      state: "completed",
    });
  }

  if (job.failed_at && job.state === "dead") {
    events.push({
      label: "Dead",
      time: job.failed_at,
      state: "dead",
    });
  }

  // Sort by time
  events.sort((a, b) => new Date(a.time).getTime() - new Date(b.time).getTime());
  return events;
}

export function JobTimeline({ job }: { job: Job }) {
  const events = buildTimeline(job);

  if (events.length === 0) return null;

  return (
    <div className="space-y-0">
      {events.map((event, i) => (
        <div key={i} className="flex gap-3">
          <div className="flex flex-col items-center">
            <div
              className={cn(
                "mt-1.5 h-2.5 w-2.5 rounded-full",
                STATE_DOT_COLORS[event.state] || "bg-gray-400",
              )}
            />
            {i < events.length - 1 && (
              <div className="w-px flex-1 bg-border" />
            )}
          </div>
          <div className="pb-4">
            <p className="text-sm font-medium">{event.label}</p>
            <p className="text-xs text-muted-foreground">{timeAgo(event.time)}</p>
            {event.detail && (
              <p className="mt-0.5 text-xs text-muted-foreground">
                {event.detail}
              </p>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
