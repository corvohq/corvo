import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useEnqueueJob } from "@/hooks/use-mutations";

interface EnqueueDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function EnqueueDialog({ open, onOpenChange }: EnqueueDialogProps) {
  const [queue, setQueue] = useState("");
  const [payload, setPayload] = useState("{}");
  const [priority, setPriority] = useState("normal");
  const [maxRetries, setMaxRetries] = useState("");
  const [scheduledAt, setScheduledAt] = useState("");
  const [uniqueKey, setUniqueKey] = useState("");
  const enqueue = useEnqueueJob();

  const reset = () => {
    setQueue("");
    setPayload("{}");
    setPriority("normal");
    setMaxRetries("");
    setScheduledAt("");
    setUniqueKey("");
  };

  const handleSubmit = () => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(payload);
    } catch {
      return;
    }

    enqueue.mutate(
      {
        queue,
        payload: parsed,
        priority,
        ...(maxRetries ? { max_retries: parseInt(maxRetries, 10) } : {}),
        ...(scheduledAt ? { scheduled_at: new Date(scheduledAt).toISOString() } : {}),
        ...(uniqueKey ? { unique_key: uniqueKey } : {}),
      },
      {
        onSuccess: () => {
          onOpenChange(false);
          reset();
        },
      },
    );
  };

  let payloadValid = true;
  try {
    JSON.parse(payload);
  } catch {
    payloadValid = false;
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Enqueue Job</DialogTitle>
          <DialogDescription>Create a new job and add it to a queue.</DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div>
            <label className="mb-1 block text-sm font-medium">Queue name *</label>
            <Input
              placeholder="e.g. emails"
              value={queue}
              onChange={(e) => setQueue(e.target.value)}
            />
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium">Payload (JSON)</label>
            <textarea
              className="flex min-h-[80px] w-full rounded-md border border-input bg-transparent px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
              value={payload}
              onChange={(e) => setPayload(e.target.value)}
            />
            {!payloadValid && (
              <p className="mt-1 text-xs text-destructive">Invalid JSON</p>
            )}
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="mb-1 block text-sm font-medium">Priority</label>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm"
                value={priority}
                onChange={(e) => setPriority(e.target.value)}
              >
                <option value="critical">Critical</option>
                <option value="high">High</option>
                <option value="normal">Normal</option>
              </select>
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium">Max retries</label>
              <Input
                type="number"
                min="0"
                placeholder="Default"
                value={maxRetries}
                onChange={(e) => setMaxRetries(e.target.value)}
              />
            </div>
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium">Scheduled at</label>
            <input
              type="datetime-local"
              className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm"
              value={scheduledAt}
              onChange={(e) => setScheduledAt(e.target.value)}
            />
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium">Unique key</label>
            <Input
              placeholder="Optional dedup key"
              value={uniqueKey}
              onChange={(e) => setUniqueKey(e.target.value)}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            onClick={handleSubmit}
            disabled={!queue || !payloadValid || enqueue.isPending}
          >
            {enqueue.isPending ? "Enqueuing..." : "Enqueue"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
