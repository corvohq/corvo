import { useState, useEffect } from "react";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "sonner";
import { toast } from "sonner";
import { Shell } from "@/components/layout/shell";
import { useSSE } from "@/hooks/use-events";
import {
  onAuthRequired,
  setStoredApiKey,
  getStoredApiKey,
} from "@/lib/api";
import Dashboard from "@/pages/dashboard";
import QueuesPage from "@/pages/queues-page";
import QueueDetail from "@/pages/queue-detail";
import JobDetailPage from "@/pages/job-detail-page";
import DeadLetter from "@/pages/dead-letter";
import HeldJobs from "@/pages/held-jobs";
import CostDashboard from "@/pages/cost-dashboard";
import WorkersPage from "@/pages/workers-page";
import ClusterPage from "@/pages/cluster-page";
import ScheduledJobs from "@/pages/scheduled-jobs";
import EventsPage from "@/pages/events-page";
import ApiKeysPage from "@/pages/api-keys-page";
import NamespacesPage from "@/pages/namespaces-page";
import RolesPage from "@/pages/roles-page";
import SSOPage from "@/pages/sso-page";
import AuditLogsPage from "@/pages/audit-logs";

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

function AuthGate({ children }: { children: React.ReactNode }) {
  const [needsAuth, setNeedsAuth] = useState(false);
  const [keyInput, setKeyInput] = useState("");

  useEffect(() => {
    return onAuthRequired(() => setNeedsAuth(true));
  }, []);

  if (!needsAuth) {
    return <>{children}</>;
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const key = keyInput.trim();
    if (!key) return;
    setStoredApiKey(key);
    setNeedsAuth(false);
    setKeyInput("");
    queryClient.invalidateQueries();
    toast.success("API key saved");
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <h1 className="text-2xl font-bold">Corvo</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            This instance requires an API key to access the dashboard.
          </p>
        </div>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-muted-foreground mb-1">
              API Key
            </label>
            <input
              type="password"
              value={keyInput}
              onChange={(e) => setKeyInput(e.target.value)}
              placeholder="Enter your API key"
              autoFocus
              className="w-full rounded-lg border border-border bg-muted px-3 py-2 text-sm text-foreground"
            />
          </div>
          <button
            type="submit"
            disabled={!keyInput.trim()}
            className="w-full rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors disabled:opacity-50"
          >
            Sign In
          </button>
        </form>
        <p className="text-center text-xs text-muted-foreground">
          API keys are created via the CLI or the API Keys page.
          {getStoredApiKey() === null && (
            <span> If no keys have been created yet, restart without a data directory.</span>
          )}
        </p>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <AuthGate>
          <SSEProvider>
            <Routes>
              <Route element={<Shell />}>
                <Route path="/ui" element={<Dashboard />} />
                <Route path="/ui/queues" element={<QueuesPage />} />
                <Route path="/ui/queues/:name" element={<QueueDetail />} />
                <Route path="/ui/jobs/:id" element={<JobDetailPage />} />
                <Route path="/ui/dead-letter" element={<DeadLetter />} />
                <Route path="/ui/held" element={<HeldJobs />} />
                <Route path="/ui/cost" element={<CostDashboard />} />
                <Route path="/ui/workers" element={<WorkersPage />} />
                <Route path="/ui/cluster" element={<ClusterPage />} />
                <Route path="/ui/scheduled" element={<ScheduledJobs />} />
                <Route path="/ui/events" element={<EventsPage />} />
                <Route path="/ui/api-keys" element={<ApiKeysPage />} />
                <Route path="/ui/namespaces" element={<NamespacesPage />} />
                <Route path="/ui/roles" element={<RolesPage />} />
                <Route path="/ui/sso" element={<SSOPage />} />
                <Route path="/ui/audit-logs" element={<AuditLogsPage />} />
              </Route>
            </Routes>
          <Toaster position="bottom-right" />
        </SSEProvider>
      </AuthGate>
    </BrowserRouter>
  </QueryClientProvider>
  );
}
