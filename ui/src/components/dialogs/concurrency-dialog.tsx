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
import { useSetConcurrency } from "@/hooks/use-mutations";

interface ConcurrencyDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  queueName: string;
  currentMax?: number;
}

export function ConcurrencyDialog({
  open,
  onOpenChange,
  queueName,
  currentMax,
}: ConcurrencyDialogProps) {
  const [value, setValue] = useState(currentMax?.toString() || "");
  const setConcurrency = useSetConcurrency();

  const handleSave = () => {
    setConcurrency.mutate(
      { name: queueName, max: parseInt(value) || 0 },
      { onSuccess: () => onOpenChange(false) },
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Set Concurrency</DialogTitle>
          <DialogDescription>
            Maximum concurrent jobs for queue &ldquo;{queueName}&rdquo;. Set to
            0 for unlimited.
          </DialogDescription>
        </DialogHeader>
        <Input
          type="number"
          min="0"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="Max concurrent jobs"
        />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={handleSave} disabled={setConcurrency.isPending}>
            {setConcurrency.isPending ? "Saving..." : "Save"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
