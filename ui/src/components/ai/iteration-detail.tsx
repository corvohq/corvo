interface IterationDetailProps {
  iteration: {
    request?: unknown;
    response?: unknown;
    tool_calls?: unknown[];
  };
}

export function IterationDetail({ iteration }: IterationDetailProps) {
  return (
    <div className="space-y-3 border-t bg-muted/30 p-4">
      {iteration.request != null && (
        <div>
          <h4 className="mb-1 text-xs font-medium text-muted-foreground">
            Request
          </h4>
          <pre className="overflow-auto rounded bg-muted p-2 text-xs">
            {JSON.stringify(iteration.request, null, 2)}
          </pre>
        </div>
      )}
      {iteration.response != null && (
        <div>
          <h4 className="mb-1 text-xs font-medium text-muted-foreground">
            Response
          </h4>
          <pre className="overflow-auto rounded bg-muted p-2 text-xs whitespace-pre-wrap">
            {typeof iteration.response === "string"
              ? iteration.response
              : JSON.stringify(iteration.response, null, 2)}
          </pre>
        </div>
      )}
      {iteration.tool_calls && iteration.tool_calls.length > 0 && (
        <div>
          <h4 className="mb-1 text-xs font-medium text-muted-foreground">
            Tool Calls ({iteration.tool_calls.length})
          </h4>
          <pre className="overflow-auto rounded bg-muted p-2 text-xs">
            {JSON.stringify(iteration.tool_calls, null, 2)}
          </pre>
        </div>
      )}
      {!iteration.request && !iteration.response && !iteration.tool_calls && (
        <p className="text-xs text-muted-foreground">No detail available</p>
      )}
    </div>
  );
}
