import { useEffect } from "react";

type HotkeyMap = Record<string, (e: KeyboardEvent) => void>;

function isEditable(el: Element | null): boolean {
  if (!el) return false;
  const tag = el.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
  if ((el as HTMLElement).isContentEditable) return true;
  return false;
}

function isInDialog(el: Element | null): boolean {
  if (!el) return false;
  return !!el.closest("[role='dialog']");
}

export function useHotkeys(map: HotkeyMap) {
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (isEditable(document.activeElement)) return;
      if (isInDialog(document.activeElement)) return;

      const key = e.key;
      const fn = map[key];
      if (fn) {
        fn(e);
      }
    };

    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [map]);
}
