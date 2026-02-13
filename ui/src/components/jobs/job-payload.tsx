import { useState } from "react";
import { ChevronDown, ChevronRight, Copy, Check } from "lucide-react";
import { Button } from "@/components/ui/button";

interface JobPayloadProps {
  label: string;
  data: unknown;
  defaultOpen?: boolean;
}

export function JobPayload({ label, data, defaultOpen = false }: JobPayloadProps) {
  const [open, setOpen] = useState(defaultOpen);
  const [copied, setCopied] = useState(false);

  if (data == null) return null;

  const json = typeof data === "string" ? data : JSON.stringify(data, null, 2);

  const handleCopy = () => {
    navigator.clipboard.writeText(json);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="rounded-lg border">
      <button
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-2 p-3 text-sm font-medium hover:bg-muted/50"
      >
        {open ? (
          <ChevronDown className="h-4 w-4" />
        ) : (
          <ChevronRight className="h-4 w-4" />
        )}
        {label}
      </button>
      {open && (
        <div className="relative border-t">
          <Button
            variant="ghost"
            size="icon"
            className="absolute right-2 top-2 h-7 w-7"
            onClick={handleCopy}
          >
            {copied ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
          </Button>
          <pre className="overflow-auto p-4 text-xs leading-relaxed">
            <code>{json}</code>
          </pre>
        </div>
      )}
    </div>
  );
}
