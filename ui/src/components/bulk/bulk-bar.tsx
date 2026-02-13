import { useState } from "react";
import { Button } from "@/components/ui/button";
import { BulkConfirm } from "./bulk-confirm";
import { useBulkAction } from "@/hooks/use-bulk";
import { RotateCcw, Trash2, XCircle, ArrowRightLeft } from "lucide-react";

interface BulkBarProps {
  selectedIds: string[];
  onClear: () => void;
}

export function BulkBar({ selectedIds, onClear }: BulkBarProps) {
  const [action, setAction] = useState<string | null>(null);
  const [moveQueue, setMoveQueue] = useState("");
  const bulk = useBulkAction();

  if (selectedIds.length === 0) return null;

  const handleConfirm = () => {
    if (!action) return;
    bulk.mutate(
      {
        job_ids: selectedIds,
        action,
        ...(action === "move" ? { move_to_queue: moveQueue } : {}),
      },
      {
        onSuccess: () => {
          setAction(null);
          onClear();
        },
      },
    );
  };

  return (
    <>
      <div className="sticky bottom-0 z-10 flex items-center gap-3 border-t bg-background px-4 py-3 shadow-lg">
        <span className="text-sm font-medium">
          {selectedIds.length} selected
        </span>
        <div className="flex gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => setAction("retry")}
          >
            <RotateCcw className="mr-1 h-3 w-3" /> Retry
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setAction("cancel")}
          >
            <XCircle className="mr-1 h-3 w-3" /> Cancel
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setAction("move")}
          >
            <ArrowRightLeft className="mr-1 h-3 w-3" /> Move
          </Button>
          <Button
            variant="destructive"
            size="sm"
            onClick={() => setAction("delete")}
          >
            <Trash2 className="mr-1 h-3 w-3" /> Delete
          </Button>
        </div>
        <Button variant="ghost" size="sm" className="ml-auto" onClick={onClear}>
          Clear selection
        </Button>
      </div>

      <BulkConfirm
        open={action !== null}
        onOpenChange={(open) => !open && setAction(null)}
        action={action || ""}
        count={selectedIds.length}
        onConfirm={handleConfirm}
        isPending={bulk.isPending}
        showQueueInput={action === "move"}
        queueValue={moveQueue}
        onQueueChange={setMoveQueue}
      />
    </>
  );
}
