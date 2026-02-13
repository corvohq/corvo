import { useCluster } from "@/hooks/use-cluster";
import { useTheme } from "@/hooks/use-theme";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Menu, Sun, Moon } from "lucide-react";

interface HeaderProps {
  onMenuClick: () => void;
}

export function Header({ onMenuClick }: HeaderProps) {
  const { data: cluster } = useCluster();
  const { theme, toggle } = useTheme();

  return (
    <header className="flex h-14 items-center justify-between border-b px-6">
      <Button
        variant="ghost"
        size="sm"
        className="md:hidden"
        onClick={onMenuClick}
      >
        <Menu className="h-5 w-5" />
      </Button>
      <div className="hidden md:block" />
      <div className="flex items-center gap-2">
        {cluster && (
          <>
            <Badge
              variant="outline"
              className={
                cluster.status === "healthy"
                  ? "border-green-500 text-green-600"
                  : "border-red-500 text-red-600"
              }
            >
              {cluster.status}
            </Badge>
            <Badge variant="outline">{cluster.mode}</Badge>
          </>
        )}
        <Button variant="ghost" size="sm" onClick={toggle}>
          {theme === "dark" ? (
            <Sun className="h-4 w-4" />
          ) : (
            <Moon className="h-4 w-4" />
          )}
        </Button>
      </div>
    </header>
  );
}
