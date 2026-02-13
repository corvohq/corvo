import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import {
  usePauseQueue,
  useResumeQueue,
  useClearQueue,
  useDrainQueue,
  useSetConcurrency,
  useSetThrottle,
} from "@/hooks/use-mutations";
import type { QueueInfo } from "@/lib/types";
import { Pause, Play, Trash2, ArrowDown, Settings, Gauge } from "lucide-react";

export function QueueActions({ queue }: { queue: QueueInfo }) {
  const pauseQueue = usePauseQueue();
  const resumeQueue = useResumeQueue();
  const clearQueue = useClearQueue();
  const drainQueue = useDrainQueue();
  const setConcurrency = useSetConcurrency();
  const setThrottle = useSetThrottle();

  const [concurrencyOpen, setConcurrencyOpen] = useState(false);
  const [throttleOpen, setThrottleOpen] = useState(false);
  const [concurrencyVal, setConcurrencyVal] = useState(
    queue.max_concurrency?.toString() || "",
  );
  const [throttleRate, setThrottleRate] = useState(
    queue.rate_limit?.toString() || "",
  );
  const [throttleWindow, setThrottleWindow] = useState(
    queue.rate_window_ms?.toString() || "1000",
  );

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

      {/* Concurrency Dialog */}
      <Dialog open={concurrencyOpen} onOpenChange={setConcurrencyOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Set Concurrency</DialogTitle>
            <DialogDescription>
              Maximum concurrent jobs for queue "{queue.name}". Set to 0 for
              unlimited.
            </DialogDescription>
          </DialogHeader>
          <Input
            type="number"
            min="0"
            value={concurrencyVal}
            onChange={(e) => setConcurrencyVal(e.target.value)}
            placeholder="Max concurrent jobs"
          />
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setConcurrencyOpen(false)}
            >
              Cancel
            </Button>
            <Button
              onClick={() => {
                setConcurrency.mutate({
                  name: queue.name,
                  max: parseInt(concurrencyVal) || 0,
                });
                setConcurrencyOpen(false);
              }}
            >
              Save
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Throttle Dialog */}
      <Dialog open={throttleOpen} onOpenChange={setThrottleOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Set Rate Limit</DialogTitle>
            <DialogDescription>
              Maximum jobs per time window for queue "{queue.name}".
            </DialogDescription>
          </DialogHeader>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="mb-1 block text-sm">Rate (jobs)</label>
              <Input
                type="number"
                min="1"
                value={throttleRate}
                onChange={(e) => setThrottleRate(e.target.value)}
              />
            </div>
            <div>
              <label className="mb-1 block text-sm">Window (ms)</label>
              <Input
                type="number"
                min="100"
                value={throttleWindow}
                onChange={(e) => setThrottleWindow(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setThrottleOpen(false)}>
              Cancel
            </Button>
            <Button
              onClick={() => {
                setThrottle.mutate({
                  name: queue.name,
                  rate: parseInt(throttleRate) || 1,
                  window_ms: parseInt(throttleWindow) || 1000,
                });
                setThrottleOpen(false);
              }}
            >
              Save
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
