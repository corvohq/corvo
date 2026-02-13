import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";

const shortcuts = [
  { key: "?", description: "Show keyboard shortcuts" },
  { key: "/", description: "Focus search input" },
  { key: "j", description: "Next row" },
  { key: "k", description: "Previous row" },
  { key: "Enter", description: "Open focused job" },
];

interface HotkeyHelpDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function HotkeyHelpDialog({ open, onOpenChange }: HotkeyHelpDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Keyboard Shortcuts</DialogTitle>
          <DialogDescription>
            Navigate faster with keyboard shortcuts.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-1">
          {shortcuts.map((s) => (
            <div
              key={s.key}
              className="flex items-center justify-between rounded px-2 py-1.5 hover:bg-muted/50"
            >
              <span className="text-sm">{s.description}</span>
              <kbd className="rounded border bg-muted px-2 py-0.5 font-mono text-xs">
                {s.key}
              </kbd>
            </div>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  );
}
