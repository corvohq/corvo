import { useParams } from "react-router-dom";
import { useJob } from "@/hooks/use-job";
import { JobDetail } from "@/components/jobs/job-detail";

export default function JobDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: job, isLoading, error } = useJob(id || "");

  if (isLoading) {
    return (
      <div className="flex h-64 items-center justify-center text-sm text-muted-foreground">
        Loading job...
      </div>
    );
  }

  if (error || !job) {
    return (
      <div className="flex h-64 items-center justify-center text-sm text-destructive">
        {error?.message || "Job not found"}
      </div>
    );
  }

  return <JobDetail job={job} />;
}
