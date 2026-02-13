import { useNavigate } from "react-router-dom";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { StateBadge } from "@/components/jobs/state-badge";
import { timeAgo, truncateId } from "@/lib/utils";
import type { Job } from "@/lib/types";
import { Check, X, Eye } from "lucide-react";

interface HeldCardProps {
  job: Job;
}

export function HeldCard({ job }: HeldCardProps) {
  const navigate = useNavigate();

  // Hold reason/payload would come from tags or payload
  const holdReason =
    (job.tags as Record<string, string> | undefined)?.hold_reason || "Awaiting approval";

  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-start justify-between">
          <div>
            <CardTitle className="font-mono text-sm">
              {truncateId(job.id)}
            </CardTitle>
            <div className="mt-1 flex items-center gap-2">
              <StateBadge state={job.state} />
              <Badge variant="outline">{job.queue}</Badge>
            </div>
          </div>
          <span className="text-xs text-muted-foreground">
            {timeAgo(job.created_at)}
          </span>
        </div>
      </CardHeader>
      <CardContent>
        <p className="mb-3 text-sm text-muted-foreground">{holdReason}</p>

        {job.payload != null && (
          <pre className="mb-3 max-h-[100px] overflow-auto rounded bg-muted p-2 text-xs">
            {typeof job.payload === "string"
              ? job.payload
              : JSON.stringify(job.payload, null, 2)}
          </pre>
        )}

        <div className="flex gap-2">
          <Button
            variant="default"
            size="sm"
            onClick={() => {
              // Future: POST /api/v1/jobs/{id}/approve
            }}
          >
            <Check className="mr-1 h-3 w-3" /> Approve
          </Button>
          <Button
            variant="destructive"
            size="sm"
            onClick={() => {
              // Future: POST /api/v1/jobs/{id}/reject
            }}
          >
            <X className="mr-1 h-3 w-3" /> Reject
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => navigate(`/ui/jobs/${job.id}`)}
          >
            <Eye className="mr-1 h-3 w-3" /> View
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
