// Library entry point — exports corvo UI pages and SSE provider
// for embedding in the Corvo Cloud console.
import "./app.css";

// Pages
export { default as Dashboard } from "@/pages/dashboard";
export { default as QueuesPage } from "@/pages/queues-page";
export { default as QueueDetail } from "@/pages/queue-detail";
export { default as JobDetailPage } from "@/pages/job-detail-page";
export { default as DeadLetter } from "@/pages/dead-letter";
export { default as HeldJobs } from "@/pages/held-jobs";
export { default as ScheduledJobs } from "@/pages/scheduled-jobs";
export { default as WorkersPage } from "@/pages/workers-page";
export { default as ClusterPage } from "@/pages/cluster-page";
export { default as CostDashboard } from "@/pages/cost-dashboard";
export { default as EventsPage } from "@/pages/events-page";

// SSE provider — wraps children with real-time query invalidation
export { useSSE } from "@/hooks/use-events";

// Types
export type * from "@/lib/types";
