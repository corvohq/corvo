import { useMutation, useQueryClient } from "@tanstack/react-query";
import { post, del } from "@/lib/api";
import { toast } from "sonner";

function useInvalidate() {
  const qc = useQueryClient();
  return () => {
    qc.invalidateQueries({ queryKey: ["search"] });
    qc.invalidateQueries({ queryKey: ["queues"] });
    qc.invalidateQueries({ queryKey: ["job"] });
    qc.invalidateQueries({ queryKey: ["workers"] });
  };
}

export function useRetryJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => post(`/jobs/${id}/retry`),
    onSuccess: () => { invalidate(); toast.success("Job retried"); },
    onError: (e) => toast.error(`Retry failed: ${e.message}`),
  });
}

export function useCancelJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => post(`/jobs/${id}/cancel`),
    onSuccess: () => { invalidate(); toast.success("Job cancelled"); },
    onError: (e) => toast.error(`Cancel failed: ${e.message}`),
  });
}

export function useHoldJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => post(`/jobs/${id}/hold`),
    onSuccess: () => { invalidate(); toast.success("Job held"); },
    onError: (e) => toast.error(`Hold failed: ${e.message}`),
  });
}

export function useApproveJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => post(`/jobs/${id}/approve`),
    onSuccess: () => { invalidate(); toast.success("Job approved"); },
    onError: (e) => toast.error(`Approve failed: ${e.message}`),
  });
}

export function useRejectJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => post(`/jobs/${id}/reject`),
    onSuccess: () => { invalidate(); toast.success("Job rejected"); },
    onError: (e) => toast.error(`Reject failed: ${e.message}`),
  });
}

export function useDeleteJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => del(`/jobs/${id}`),
    onSuccess: () => { invalidate(); toast.success("Job deleted"); },
    onError: (e) => toast.error(`Delete failed: ${e.message}`),
  });
}

export function useMoveJob() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ id, queue }: { id: string; queue: string }) =>
      post(`/jobs/${id}/move`, { queue }),
    onSuccess: () => { invalidate(); toast.success("Job moved"); },
    onError: (e) => toast.error(`Move failed: ${e.message}`),
  });
}

export function usePauseQueue() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (name: string) => post(`/queues/${name}/pause`),
    onSuccess: () => { invalidate(); toast.success("Queue paused"); },
    onError: (e) => toast.error(`Pause failed: ${e.message}`),
  });
}

export function useResumeQueue() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (name: string) => post(`/queues/${name}/resume`),
    onSuccess: () => { invalidate(); toast.success("Queue resumed"); },
    onError: (e) => toast.error(`Resume failed: ${e.message}`),
  });
}

export function useClearQueue() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (name: string) => post(`/queues/${name}/clear`),
    onSuccess: () => { invalidate(); toast.success("Queue cleared"); },
    onError: (e) => toast.error(`Clear failed: ${e.message}`),
  });
}

export function useDrainQueue() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (name: string) => post(`/queues/${name}/drain`),
    onSuccess: () => { invalidate(); toast.success("Queue draining"); },
    onError: (e) => toast.error(`Drain failed: ${e.message}`),
  });
}

export function useSetConcurrency() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ name, max }: { name: string; max: number }) =>
      post(`/queues/${name}/concurrency`, { max }),
    onSuccess: () => { invalidate(); toast.success("Concurrency updated"); },
    onError: (e) => toast.error(`Failed: ${e.message}`),
  });
}

export function useSetThrottle() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ name, rate, window_ms }: { name: string; rate: number; window_ms: number }) =>
      post(`/queues/${name}/throttle`, { rate, window_ms }),
    onSuccess: () => { invalidate(); toast.success("Throttle updated"); },
    onError: (e) => toast.error(`Failed: ${e.message}`),
  });
}

export function useDeleteQueue() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (name: string) => del(`/queues/${name}`),
    onSuccess: () => { invalidate(); toast.success("Queue deleted"); },
    onError: (e) => toast.error(`Delete failed: ${e.message}`),
  });
}
