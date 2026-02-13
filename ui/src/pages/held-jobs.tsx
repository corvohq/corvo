import { useSearch } from "@/hooks/use-search";
import { HeldCard } from "@/components/ai/held-card";

export default function HeldJobs() {
  // "held" state doesn't exist in the backend yet — this will return empty
  const { data: searchResult, isLoading } = useSearch({
    state: ["held"],
    limit: 50,
    sort: "created_at",
    order: "desc",
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Held Jobs</h1>
        <p className="text-sm text-muted-foreground">
          Jobs awaiting human approval before proceeding.
        </p>
      </div>

      {isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </p>
      )}

      {!isLoading && (!searchResult?.jobs || searchResult.jobs.length === 0) && (
        <div className="rounded-lg border border-dashed p-12 text-center">
          <p className="text-sm text-muted-foreground">
            No held jobs. When AI agent jobs require human approval, they will
            appear here.
          </p>
        </div>
      )}

      {searchResult?.jobs && searchResult.jobs.length > 0 && (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {searchResult.jobs.map((job) => (
            <HeldCard key={job.id} job={job} />
          ))}
        </div>
      )}
    </div>
  );
}
