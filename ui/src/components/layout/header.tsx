import { useCluster } from "@/hooks/use-cluster";
import { Badge } from "@/components/ui/badge";

export function Header() {
  const { data: cluster } = useCluster();

  return (
    <header className="flex h-14 items-center justify-between border-b px-6">
      <div />
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
      </div>
    </header>
  );
}
