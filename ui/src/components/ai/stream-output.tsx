import { useEffect, useRef } from "react";
import { ScrollArea } from "@/components/ui/scroll-area";

interface StreamOutputProps {
  content: string;
  isStreaming?: boolean;
}

export function StreamOutput({ content, isStreaming }: StreamOutputProps) {
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [content]);

  return (
    <ScrollArea className="h-[400px] rounded-md border bg-muted/30">
      <pre className="p-4 font-mono text-xs leading-relaxed whitespace-pre-wrap">
        {content || (
          <span className="text-muted-foreground">No output yet</span>
        )}
        {isStreaming && (
          <span className="animate-pulse text-primary">|</span>
        )}
      </pre>
      <div ref={bottomRef} />
    </ScrollArea>
  );
}
