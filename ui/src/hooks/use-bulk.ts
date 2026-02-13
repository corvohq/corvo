import { useMutation, useQueryClient } from "@tanstack/react-query";
import { post } from "@/lib/api";
import type { BulkRequest, BulkResult } from "@/lib/types";
import { toast } from "sonner";

export function useBulkAction() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (req: BulkRequest) => post<BulkResult>("/jobs/bulk", req),
    onSuccess: (data) => {
      qc.invalidateQueries({ queryKey: ["search"] });
      qc.invalidateQueries({ queryKey: ["queues"] });
      qc.invalidateQueries({ queryKey: ["job"] });
      toast.success(`Bulk action: ${data.affected} affected, ${data.errors} errors (${data.duration_ms}ms)`);
    },
    onError: (e) => toast.error(`Bulk action failed: ${e.message}`),
  });
}
