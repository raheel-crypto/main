import { useState } from "react";
import { Link } from "react-router-dom";
import { cn } from "../../lib/utils";
import type { FlowSummary } from "../../lib/api";

interface FlowListProps {
  flows: FlowSummary[];
  isLoading: boolean;
}

const typeColors: Record<string, string> = {
  AutoLaunchedFlow: "bg-purple-500/10 text-purple-400",
  Flow: "bg-blue-500/10 text-blue-400",
  Workflow: "bg-orange-500/10 text-orange-400",
  CustomEvent: "bg-green-500/10 text-green-400",
  InvocableProcess: "bg-cyan-500/10 text-cyan-400",
};

const statusColors: Record<string, string> = {
  Active: "bg-green-500/10 text-green-400",
  Draft: "bg-yellow-500/10 text-yellow-400",
  Obsolete: "bg-red-500/10 text-red-400",
  InvalidDraft: "bg-orange-500/10 text-orange-400",
};

export function FlowList({ flows, isLoading }: FlowListProps) {
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>("all");

  // Get unique statuses from the data
  const statuses = Array.from(new Set(flows.map((f) => f.status))).sort();

  const filtered = flows.filter((f) => {
    const matchesSearch =
      f.label.toLowerCase().includes(search.toLowerCase()) ||
      f.name.toLowerCase().includes(search.toLowerCase());
    const matchesStatus =
      statusFilter === "all" ||
      f.status.toLowerCase() === statusFilter.toLowerCase();
    return matchesSearch && matchesStatus;
  });

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 6 }).map((_, i) => (
          <div
            key={i}
            className="h-16 animate-pulse rounded-lg bg-muted"
          />
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <input
          type="text"
          placeholder="Search flows..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="flex-1 max-w-md rounded-lg border border-input bg-background px-4 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        />
        <div className="flex rounded-lg border border-input">
          <button
            onClick={() => setStatusFilter("all")}
            className={cn(
              "px-3 py-2 text-xs font-medium transition-colors",
              statusFilter === "all"
                ? "bg-accent text-accent-foreground"
                : "text-muted-foreground hover:text-foreground"
            )}
          >
            All
          </button>
          {statuses.map((status) => (
            <button
              key={status}
              onClick={() => setStatusFilter(status)}
              className={cn(
                "px-3 py-2 text-xs font-medium transition-colors",
                statusFilter === status
                  ? "bg-accent text-accent-foreground"
                  : "text-muted-foreground hover:text-foreground"
              )}
            >
              {status}
            </button>
          ))}
        </div>
      </div>

      <div className="text-xs text-muted-foreground">
        {filtered.length} of {flows.length} flows
      </div>

      <div className="space-y-1">
        {filtered.map((flow) => (
          <Link
            key={flow.id}
            to={`/flows/${flow.id}`}
            className="flex items-center justify-between rounded-lg border border-transparent px-4 py-3 transition-colors hover:border-border hover:bg-accent/50"
          >
            <div className="space-y-1">
              <div className="flex items-center gap-2">
                <span className="text-sm font-medium text-foreground">
                  {flow.label}
                </span>
                <span
                  className={cn(
                    "rounded-full px-2 py-0.5 text-xs font-medium",
                    statusColors[flow.status] || "bg-muted text-muted-foreground"
                  )}
                >
                  {flow.status}
                </span>
              </div>
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                <span
                  className={cn(
                    "rounded px-1.5 py-0.5",
                    typeColors[flow.type] || "bg-muted text-muted-foreground"
                  )}
                >
                  {flow.type}
                </span>
                {flow.triggerObject && (
                  <span>
                    Trigger: {flow.triggerObject}
                    {flow.triggerType && ` (${flow.triggerType})`}
                  </span>
                )}
              </div>
            </div>
            <svg
              className="h-4 w-4 text-muted-foreground"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <polyline points="9,18 15,12 9,6" />
            </svg>
          </Link>
        ))}
      </div>
    </div>
  );
}
