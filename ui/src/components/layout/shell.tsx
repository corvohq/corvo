import { useState, useMemo } from "react";
import { Outlet } from "react-router-dom";
import { Sidebar } from "./sidebar";
import { Header } from "./header";
import { HotkeyHelpDialog } from "@/components/dialogs/hotkey-help-dialog";
import { useHotkeys } from "@/hooks/use-hotkeys";

export function Shell() {
  const [mobileOpen, setMobileOpen] = useState(false);
  const [helpOpen, setHelpOpen] = useState(false);

  const hotkeyMap = useMemo(
    () => ({
      "?": () => setHelpOpen(true),
      "/": (e: KeyboardEvent) => {
        e.preventDefault();
        const el = document.querySelector<HTMLInputElement>(
          "[data-search-input]",
        );
        el?.focus();
      },
    }),
    [],
  );

  useHotkeys(hotkeyMap);

  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar mobileOpen={mobileOpen} onMobileOpenChange={setMobileOpen} />
      <div className="flex flex-1 flex-col overflow-hidden">
        <Header onMenuClick={() => setMobileOpen(true)} />
        <main className="flex-1 overflow-auto p-6">
          <Outlet />
        </main>
      </div>
      <HotkeyHelpDialog open={helpOpen} onOpenChange={setHelpOpen} />
    </div>
  );
}
