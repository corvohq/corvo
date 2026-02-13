import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { WorkerTable } from "@/components/workers/worker-table";
import { useWorkers } from "@/hooks/use-workers";

export default function WorkersPage() {
  const { data: workers, isLoading } = useWorkers();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Workers</h1>
        <p className="text-sm text-muted-foreground">
          Connected workers and their status.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">
            Active Workers
            {workers && (
              <span className="ml-2 font-normal text-muted-foreground">
                ({workers.length})
              </span>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="py-8 text-center text-sm text-muted-foreground">
              Loading...
            </p>
          ) : (
            <WorkerTable workers={workers || []} />
          )}
        </CardContent>
      </Card>
    </div>
  );
}
