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
import { useSetThrottle } from "@/hooks/use-mutations";

interface ThrottleDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  queueName: string;
  currentRate?: number;
  currentWindowMs?: number;
}

export function ThrottleDialog({
  open,
  onOpenChange,
  queueName,
  currentRate,
  currentWindowMs,
}: ThrottleDialogProps) {
  const [rate, setRate] = useState(currentRate?.toString() || "");
  const [windowMs, setWindowMs] = useState(
    currentWindowMs?.toString() || "1000",
  );
  const setThrottle = useSetThrottle();

  const handleSave = () => {
    setThrottle.mutate(
      {
        name: queueName,
        rate: parseInt(rate) || 1,
        window_ms: parseInt(windowMs) || 1000,
      },
      { onSuccess: () => onOpenChange(false) },
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Set Rate Limit</DialogTitle>
          <DialogDescription>
            Maximum jobs per time window for queue &ldquo;{queueName}&rdquo;.
          </DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="mb-1 block text-sm">Rate (jobs)</label>
            <Input
              type="number"
              min="1"
              value={rate}
              onChange={(e) => setRate(e.target.value)}
            />
          </div>
          <div>
            <label className="mb-1 block text-sm">Window (ms)</label>
            <Input
              type="number"
              min="100"
              value={windowMs}
              onChange={(e) => setWindowMs(e.target.value)}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={handleSave} disabled={setThrottle.isPending}>
            {setThrottle.isPending ? "Saving..." : "Save"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
