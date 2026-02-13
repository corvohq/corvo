import { NavLink } from "react-router-dom";
import { cn } from "@/lib/utils";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import {
  LayoutDashboard,
  Layers,
  ListOrdered,
  Skull,
  HandMetal,
  DollarSign,
  Users,
  Network,
} from "lucide-react";

const navItems = [
  { to: "/ui", icon: LayoutDashboard, label: "Dashboard", end: true },
  { to: "/ui/queues", icon: ListOrdered, label: "Queues" },
  { to: "/ui/dead-letter", icon: Skull, label: "Dead Letter" },
  { to: "/ui/held", icon: HandMetal, label: "Held Jobs" },
  { to: "/ui/cost", icon: DollarSign, label: "Cost" },
  { to: "/ui/workers", icon: Users, label: "Workers" },
  { to: "/ui/cluster", icon: Network, label: "Cluster" },
];

interface SidebarProps {
  mobileOpen: boolean;
  onMobileOpenChange: (open: boolean) => void;
}

function SidebarContent({ onNavigate }: { onNavigate?: () => void }) {
  return (
    <>
      <div className="flex h-14 items-center border-b px-4">
        <NavLink to="/ui" className="flex items-center gap-2" onClick={onNavigate}>
          <Layers className="h-5 w-5" />
          <span className="text-lg font-bold tracking-tight">Jobbie</span>
        </NavLink>
      </div>
      <nav className="flex-1 space-y-1 p-3">
        {navItems.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.end}
            onClick={onNavigate}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
                isActive
                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                  : "text-sidebar-foreground/70 hover:bg-sidebar-accent/50 hover:text-sidebar-foreground",
              )
            }
          >
            <item.icon className="h-4 w-4" />
            {item.label}
          </NavLink>
        ))}
      </nav>
    </>
  );
}

export function Sidebar({ mobileOpen, onMobileOpenChange }: SidebarProps) {
  return (
    <>
      {/* Desktop sidebar */}
      <aside className="hidden h-full w-56 flex-col border-r bg-sidebar md:flex">
        <SidebarContent />
      </aside>

      {/* Mobile sidebar (sheet) */}
      <Sheet open={mobileOpen} onOpenChange={onMobileOpenChange}>
        <SheetContent side="left" className="w-56 bg-sidebar p-0">
          <SidebarContent onNavigate={() => onMobileOpenChange(false)} />
        </SheetContent>
      </Sheet>
    </>
  );
}
