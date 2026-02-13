export const STATE_COLORS: Record<string, string> = {
  pending: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200",
  active: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
  completed: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
  retrying: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200",
  dead: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  cancelled: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200",
  scheduled: "bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-200",
  held: "bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200",
};

export const STATE_DOT_COLORS: Record<string, string> = {
  pending: "bg-yellow-500",
  active: "bg-blue-500",
  completed: "bg-green-500",
  retrying: "bg-orange-500",
  dead: "bg-red-500",
  cancelled: "bg-gray-500",
  scheduled: "bg-purple-500",
  held: "bg-amber-500",
};

export const PRIORITY_LABELS: Record<number, string> = {
  0: "Critical",
  1: "High",
  2: "Normal",
};

export const PRIORITY_COLORS: Record<number, string> = {
  0: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  1: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200",
  2: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200",
};

export const ALL_STATES = [
  "pending",
  "active",
  "completed",
  "retrying",
  "dead",
  "cancelled",
  "scheduled",
] as const;

export const BULK_ACTIONS = [
  { value: "retry", label: "Retry" },
  { value: "cancel", label: "Cancel" },
  { value: "delete", label: "Delete" },
  { value: "move", label: "Move" },
  { value: "requeue", label: "Requeue" },
  { value: "change_priority", label: "Change Priority" },
] as const;
