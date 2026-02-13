import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { BulkConfirm } from "./bulk-confirm";
import { useBulkAction } from "@/hooks/use-bulk";
import { RotateCcw, Trash2, XCircle, ArrowRightLeft, Loader2 } from "lucide-react";

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
      <div className="sticky bottom-0 z-10 border-t bg-background shadow-lg">
        {bulk.isPending && (
          <Progress className="h-1 rounded-none" />
        )}
        <div className="flex items-center gap-3 px-4 py-3">
          {bulk.isPending ? (
            <span className="flex items-center gap-2 text-sm font-medium">
              <Loader2 className="h-4 w-4 animate-spin" />
              Processing {selectedIds.length} jobs...
            </span>
          ) : (
            <>
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
            </>
          )}
        </div>
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
