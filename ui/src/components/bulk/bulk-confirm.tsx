import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

interface BulkConfirmProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  action: string;
  count: number;
  onConfirm: () => void;
  isPending: boolean;
  showQueueInput?: boolean;
  queueValue?: string;
  onQueueChange?: (value: string) => void;
}

export function BulkConfirm({
  open,
  onOpenChange,
  action,
  count,
  onConfirm,
  isPending,
  showQueueInput,
  queueValue,
  onQueueChange,
}: BulkConfirmProps) {
  const isDestructive = action === "delete";

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="capitalize">Bulk {action}</DialogTitle>
          <DialogDescription>
            This will {action} {count} job{count !== 1 ? "s" : ""}. This action
            cannot be undone.
          </DialogDescription>
        </DialogHeader>

        {showQueueInput && (
          <div>
            <label className="mb-1 block text-sm text-muted-foreground">
              Destination queue
            </label>
            <Input
              placeholder="Queue name..."
              value={queueValue}
              onChange={(e) => onQueueChange?.(e.target.value)}
            />
          </div>
        )}

        <DialogFooter>
          <Button
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={isPending}
          >
            Cancel
          </Button>
          <Button
            variant={isDestructive ? "destructive" : "default"}
            onClick={onConfirm}
            disabled={isPending || (showQueueInput && !queueValue)}
          >
            {isPending ? "Processing..." : `${action} ${count} jobs`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
