import { useState } from "react";
import { cn } from "../lib/utils";
import { api, CleanupFinding } from "../lib/api";

const severityConfig = {
  high: { color: "text-red-400", bg: "bg-red-500/10", border: "border-red-500/20", label: "High" },
  medium: { color: "text-yellow-400", bg: "bg-yellow-500/10", border: "border-yellow-500/20", label: "Medium" },
  low: { color: "text-blue-400", bg: "bg-blue-500/10", border: "border-blue-500/20", label: "Low" },
};

const categoryIcons: Record<string, string> = {
  "Unused Fields": "database",
  "Stale Flows": "workflow",
  "Unused Permissions": "shield",
  "Inactive Users": "users",
};

export function CleanupPage() {
  const [findings, setFindings] = useState<CleanupFinding[]>([]);
  const [isScanning, setIsScanning] = useState(false);
  const [hasScanned, setHasScanned] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [categoryFilter, setCategoryFilter] = useState<string>("all");
  const [severityFilter, setSeverityFilter] = useState<string>("all");

  const scan = async () => {
    setIsScanning(true);
    setError(null);
    try {
      const results = await api.runCleanupScan();
      setFindings(results);
      setHasScanned(true);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setIsScanning(false);
    }
  };

  const categories = Array.from(new Set(findings.map((f) => f.category)));
  const filtered = findings.filter((f) => {
    const matchesCat = categoryFilter === "all" || f.category === categoryFilter;
    const matchesSev = severityFilter === "all" || f.severity === severityFilter;
    return matchesCat && matchesSev;
  });

  const highCount = findings.filter((f) => f.severity === "high").length;
  const mediumCount = findings.filter((f) => f.severity === "medium").length;
  const lowCount = findings.filter((f) => f.severity === "low").length;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Org Cleanup Scanner</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Scan your org for unused fields, stale flows, orphaned permissions, and inactive users
        </p>
      </div>

      {/* Scan button */}
      {!hasScanned && !isScanning && (
        <div className="rounded-xl border border-border bg-card p-8 text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary/10">
            <svg className="h-8 w-8 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
            </svg>
          </div>
          <h2 className="text-lg font-semibold text-foreground">Ready to Scan</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            This will analyze your org for cleanup opportunities across fields, flows, permissions, and users.
          </p>
          <button
            onClick={scan}
            className="mt-4 rounded-lg bg-primary px-6 py-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            Start Cleanup Scan
          </button>
        </div>
      )}

      {/* Scanning */}
      {isScanning && (
        <div className="rounded-xl border border-border bg-card p-8 text-center">
          <div className="mx-auto mb-4 h-8 w-8 animate-spin rounded-full border-3 border-primary border-t-transparent" />
          <h2 className="text-lg font-semibold text-foreground">Scanning your org...</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Checking fields, flows, permissions, and users. This may take a minute.
          </p>
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-destructive/50 bg-destructive/5 p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {/* Results */}
      {hasScanned && !isScanning && (
        <>
          {/* Summary cards */}
          <div className="grid grid-cols-4 gap-4">
            <div className="rounded-lg border border-border bg-card p-4">
              <div className="text-2xl font-bold text-foreground">{findings.length}</div>
              <div className="text-xs text-muted-foreground">Total Findings</div>
            </div>
            <div className="rounded-lg border border-red-500/20 bg-red-500/5 p-4">
              <div className="text-2xl font-bold text-red-400">{highCount}</div>
              <div className="text-xs text-muted-foreground">High Severity</div>
            </div>
            <div className="rounded-lg border border-yellow-500/20 bg-yellow-500/5 p-4">
              <div className="text-2xl font-bold text-yellow-400">{mediumCount}</div>
              <div className="text-xs text-muted-foreground">Medium Severity</div>
            </div>
            <div className="rounded-lg border border-blue-500/20 bg-blue-500/5 p-4">
              <div className="text-2xl font-bold text-blue-400">{lowCount}</div>
              <div className="text-xs text-muted-foreground">Low Severity</div>
            </div>
          </div>

          {/* Filters */}
          <div className="flex items-center gap-3">
            <select
              value={categoryFilter}
              onChange={(e) => setCategoryFilter(e.target.value)}
              className="rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground"
            >
              <option value="all">All Categories</option>
              {categories.map((c) => (
                <option key={c} value={c}>
                  {c} ({findings.filter((f) => f.category === c).length})
                </option>
              ))}
            </select>
            <div className="flex rounded-lg border border-input">
              {(["all", "high", "medium", "low"] as const).map((sev) => (
                <button
                  key={sev}
                  onClick={() => setSeverityFilter(sev)}
                  className={cn(
                    "px-3 py-2 text-xs font-medium capitalize transition-colors",
                    severityFilter === sev
                      ? "bg-accent text-accent-foreground"
                      : "text-muted-foreground hover:text-foreground"
                  )}
                >
                  {sev}
                </button>
              ))}
            </div>
            <button
              onClick={scan}
              className="ml-auto rounded-lg border border-input px-3 py-2 text-xs text-muted-foreground hover:text-foreground"
            >
              Re-scan
            </button>
          </div>

          {/* Findings list */}
          <div className="space-y-2">
            {filtered.map((finding, i) => {
              const sev = severityConfig[finding.severity];
              return (
                <div
                  key={`${finding.item}-${i}`}
                  className={cn("rounded-lg border p-4", sev.border)}
                >
                  <div className="flex items-start justify-between">
                    <div className="flex-1 space-y-1">
                      <div className="flex items-center gap-2">
                        <span className={cn("rounded px-2 py-0.5 text-xs font-medium", sev.bg, sev.color)}>
                          {sev.label}
                        </span>
                        <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                          {finding.category}
                        </span>
                        {finding.object && (
                          <span className="text-xs text-muted-foreground">
                            {finding.object}
                          </span>
                        )}
                      </div>
                      <div className="text-sm font-medium text-foreground">
                        {finding.item}
                      </div>
                      <div className="text-xs text-muted-foreground">
                        {finding.detail}
                      </div>
                    </div>
                  </div>
                  <div className="mt-2 rounded bg-primary/5 px-3 py-2 text-xs text-foreground">
                    <span className="font-medium text-primary">Recommendation: </span>
                    {finding.recommendation}
                  </div>
                </div>
              );
            })}

            {filtered.length === 0 && findings.length > 0 && (
              <div className="py-8 text-center text-sm text-muted-foreground">
                No findings match the current filters.
              </div>
            )}

            {findings.length === 0 && (
              <div className="py-8 text-center text-sm text-green-400">
                No cleanup issues found. Your org is in good shape!
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
