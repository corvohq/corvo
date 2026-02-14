interface IterationDetailProps {
  iteration: {
    checkpoint?: unknown;
    result?: unknown;
    hold_reason?: string;
  };
}

export function IterationDetail({ iteration }: IterationDetailProps) {
  return (
    <div className="space-y-3 border-t bg-muted/30 p-4">
      {iteration.checkpoint != null && (
        <div>
          <h4 className="mb-1 text-xs font-medium text-muted-foreground">
            Checkpoint
          </h4>
          <pre className="overflow-auto rounded bg-muted p-2 text-xs">
            {JSON.stringify(iteration.checkpoint, null, 2)}
          </pre>
        </div>
      )}
      {iteration.result != null && (
        <div>
          <h4 className="mb-1 text-xs font-medium text-muted-foreground">
            Result
          </h4>
          <pre className="overflow-auto rounded bg-muted p-2 text-xs whitespace-pre-wrap">
            {typeof iteration.result === "string"
              ? iteration.result
              : JSON.stringify(iteration.result, null, 2)}
          </pre>
        </div>
      )}
      {iteration.hold_reason && (
        <div>
          <h4 className="mb-1 text-xs font-medium text-muted-foreground">
            Hold Reason
          </h4>
          <p className="rounded bg-muted p-2 text-xs whitespace-pre-wrap">
            {iteration.hold_reason}
          </p>
        </div>
      )}
      {!iteration.checkpoint &&
        !iteration.result &&
        !iteration.hold_reason && (
        <p className="text-xs text-muted-foreground">No detail available</p>
        )}
    </div>
  );
}
