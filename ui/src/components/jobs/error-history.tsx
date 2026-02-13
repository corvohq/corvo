import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { timeAgo } from "@/lib/utils";
import { ChevronDown, ChevronRight, Copy, Check } from "lucide-react";
import type { JobError } from "@/lib/types";

function ErrorEntry({ err, defaultOpen }: { err: JobError; defaultOpen: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  const [copied, setCopied] = useState(false);

  const copyText = () => {
    const text = err.backtrace
      ? `${err.error}\n\n${err.backtrace}`
      : err.error;
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="rounded-md border">
      <button
        className="flex w-full items-center justify-between p-3 text-left hover:bg-muted/50"
        onClick={() => setOpen(!open)}
      >
        <div className="flex items-center gap-2">
          {open ? (
            <ChevronDown className="h-3.5 w-3.5 text-muted-foreground" />
          ) : (
            <ChevronRight className="h-3.5 w-3.5 text-muted-foreground" />
          )}
          <Badge variant="outline" className="text-xs">
            Attempt {err.attempt}
          </Badge>
          <span className="text-xs text-muted-foreground">
            {timeAgo(err.created_at)}
          </span>
        </div>
        <Button
          variant="ghost"
          size="icon"
          className="h-6 w-6"
          onClick={(e) => {
            e.stopPropagation();
            copyText();
          }}
        >
          {copied ? (
            <Check className="h-3 w-3 text-green-600" />
          ) : (
            <Copy className="h-3 w-3" />
          )}
        </Button>
      </button>
      {open && (
        <div className="border-t px-3 pb-3 pt-2">
          <p className="font-mono text-xs text-destructive">{err.error}</p>
          {err.backtrace && (
            <pre className="mt-2 overflow-auto rounded bg-muted p-2 text-xs leading-relaxed">
              {err.backtrace}
            </pre>
          )}
        </div>
      )}
    </div>
  );
}

export function ErrorHistory({ errors }: { errors: JobError[] }) {
  if (!errors || errors.length === 0) return null;

  const sorted = [...errors].sort((a, b) => b.attempt - a.attempt);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm">Attempt History</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="space-y-2">
          {sorted.map((err, i) => (
            <ErrorEntry key={err.id} err={err} defaultOpen={i === 0} />
          ))}
        </div>
      </CardContent>
    </Card>
  );
}
