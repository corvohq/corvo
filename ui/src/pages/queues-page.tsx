import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueueTable } from "@/components/queues/queue-table";
import { useQueues } from "@/hooks/use-queues";

export default function QueuesPage() {
  const { data: queues, isLoading } = useQueues();

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Queues</h1>
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">
            All Queues
            {queues && (
              <span className="ml-2 font-normal text-muted-foreground">
                ({queues.length})
              </span>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading ? (
            <p className="py-8 text-center text-sm text-muted-foreground">
              Loading...
            </p>
          ) : (
            <QueueTable queues={queues || []} />
          )}
        </CardContent>
      </Card>
    </div>
  );
}
