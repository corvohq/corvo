import type { Job } from "@/lib/types";

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

export function exportJSON(jobs: Job[], filename = "jobs.json") {
  const blob = new Blob([JSON.stringify(jobs, null, 2)], {
    type: "application/json",
  });
  downloadBlob(blob, filename);
}

function escapeCSV(val: string): string {
  if (val.includes(",") || val.includes('"') || val.includes("\n")) {
    return `"${val.replace(/"/g, '""')}"`;
  }
  return val;
}

export function exportCSV(jobs: Job[], filename = "jobs.csv") {
  const headers = [
    "id",
    "queue",
    "state",
    "priority",
    "attempt",
    "max_retries",
    "created_at",
    "started_at",
    "completed_at",
    "failed_at",
  ];
  const rows = jobs.map((j) =>
    [
      j.id,
      j.queue,
      j.state,
      String(j.priority),
      String(j.attempt),
      String(j.max_retries),
      j.created_at,
      j.started_at || "",
      j.completed_at || "",
      j.failed_at || "",
    ]
      .map(escapeCSV)
      .join(","),
  );
  const csv = [headers.join(","), ...rows].join("\n");
  const blob = new Blob([csv], { type: "text/csv" });
  downloadBlob(blob, filename);
}
