import { useState } from "react";
import { Button } from "@/components/ui/button";
import { ConcurrencyDialog } from "@/components/dialogs/concurrency-dialog";
import { ThrottleDialog } from "@/components/dialogs/throttle-dialog";
import {
  usePauseQueue,
  useResumeQueue,
  useClearQueue,
  useDrainQueue,
} from "@/hooks/use-mutations";
import type { QueueInfo } from "@/lib/types";
import { Pause, Play, Trash2, ArrowDown, Settings, Gauge } from "lucide-react";

export function QueueActions({ queue }: { queue: QueueInfo }) {
  const pauseQueue = usePauseQueue();
  const resumeQueue = useResumeQueue();
  const clearQueue = useClearQueue();
  const drainQueue = useDrainQueue();

  const [concurrencyOpen, setConcurrencyOpen] = useState(false);
  const [throttleOpen, setThrottleOpen] = useState(false);

  return (
    <div className="flex flex-wrap gap-2">
      {queue.paused ? (
        <Button
          variant="outline"
          size="sm"
          onClick={() => resumeQueue.mutate(queue.name)}
        >
          <Play className="mr-1 h-3 w-3" /> Resume
        </Button>
      ) : (
        <Button
          variant="outline"
          size="sm"
          onClick={() => pauseQueue.mutate(queue.name)}
        >
          <Pause className="mr-1 h-3 w-3" /> Pause
        </Button>
      )}

      <Button
        variant="outline"
        size="sm"
        onClick={() => drainQueue.mutate(queue.name)}
      >
        <ArrowDown className="mr-1 h-3 w-3" /> Drain
      </Button>

      <Button
        variant="outline"
        size="sm"
        onClick={() => setConcurrencyOpen(true)}
      >
        <Settings className="mr-1 h-3 w-3" /> Concurrency
      </Button>

      <Button
        variant="outline"
        size="sm"
        onClick={() => setThrottleOpen(true)}
      >
        <Gauge className="mr-1 h-3 w-3" /> Throttle
      </Button>

      <Button
        variant="destructive"
        size="sm"
        onClick={() => clearQueue.mutate(queue.name)}
      >
        <Trash2 className="mr-1 h-3 w-3" /> Clear
      </Button>

      <ConcurrencyDialog
        open={concurrencyOpen}
        onOpenChange={setConcurrencyOpen}
        queueName={queue.name}
        currentMax={queue.max_concurrency}
      />

      <ThrottleDialog
        open={throttleOpen}
        onOpenChange={setThrottleOpen}
        queueName={queue.name}
        currentRate={queue.rate_limit}
        currentWindowMs={queue.rate_window_ms}
      />
    </div>
  );
}
