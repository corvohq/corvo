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
import { useMoveJob } from "@/hooks/use-mutations";
import { useState } from "react";

interface MoveDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  jobId: string;
}

export function MoveDialog({ open, onOpenChange, jobId }: MoveDialogProps) {
  const [queue, setQueue] = useState("");
  const moveJob = useMoveJob();

  const handleMove = () => {
    moveJob.mutate(
      { id: jobId, queue },
      {
        onSuccess: () => {
          onOpenChange(false);
          setQueue("");
        },
      },
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Move Job</DialogTitle>
          <DialogDescription>
            Move this job to a different queue.
          </DialogDescription>
        </DialogHeader>
        <Input
          placeholder="Destination queue name..."
          value={queue}
          onChange={(e) => setQueue(e.target.value)}
        />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={handleMove} disabled={!queue || moveJob.isPending}>
            {moveJob.isPending ? "Moving..." : "Move"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
