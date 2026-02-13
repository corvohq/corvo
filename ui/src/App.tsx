import { BrowserRouter, Routes, Route } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "sonner";
import { Shell } from "@/components/layout/shell";
import { useSSE } from "@/hooks/use-events";
import Dashboard from "@/pages/dashboard";
import QueueDetail from "@/pages/queue-detail";
import JobDetailPage from "@/pages/job-detail-page";
import DeadLetter from "@/pages/dead-letter";
import HeldJobs from "@/pages/held-jobs";
import CostDashboard from "@/pages/cost-dashboard";
import WorkersPage from "@/pages/workers-page";
import ClusterPage from "@/pages/cluster-page";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 2000,
      retry: 1,
      refetchOnWindowFocus: true,
    },
  },
});

function SSEProvider({ children }: { children: React.ReactNode }) {
  useSSE();
  return <>{children}</>;
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <SSEProvider>
        <BrowserRouter>
          <Routes>
            <Route element={<Shell />}>
              <Route path="/ui" element={<Dashboard />} />
              <Route path="/ui/queues/:name" element={<QueueDetail />} />
              <Route path="/ui/jobs/:id" element={<JobDetailPage />} />
              <Route path="/ui/dead-letter" element={<DeadLetter />} />
              <Route path="/ui/held" element={<HeldJobs />} />
              <Route path="/ui/cost" element={<CostDashboard />} />
              <Route path="/ui/workers" element={<WorkersPage />} />
              <Route path="/ui/cluster" element={<ClusterPage />} />
            </Route>
          </Routes>
        </BrowserRouter>
        <Toaster position="bottom-right" />
      </SSEProvider>
    </QueryClientProvider>
  );
}
