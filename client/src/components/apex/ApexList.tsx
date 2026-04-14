import { useState } from "react";
import { Link } from "react-router-dom";
import type { ApexSummary } from "../../lib/api";

interface ApexListProps {
  classes: ApexSummary[];
  isLoading: boolean;
}

export function ApexList({ classes, isLoading }: ApexListProps) {
  const [search, setSearch] = useState("");

  const filtered = classes.filter((c) =>
    c.name.toLowerCase().includes(search.toLowerCase())
  );

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 6 }).map((_, i) => (
          <div
            key={i}
            className="h-14 animate-pulse rounded-lg bg-muted"
          />
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <input
        type="text"
        placeholder="Search Apex classes..."
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        className="w-full max-w-md rounded-lg border border-input bg-background px-4 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
      />

      <div className="text-xs text-muted-foreground">
        {filtered.length} classes
      </div>

      <div className="space-y-1">
        {filtered.map((cls) => (
          <Link
            key={cls.id}
            to={`/apex/${cls.id}`}
            className="flex items-center justify-between rounded-lg border border-transparent px-4 py-3 transition-colors hover:border-border hover:bg-accent/50"
          >
            <div className="space-y-1">
              <div className="flex items-center gap-2">
                <div className="flex h-7 w-7 items-center justify-center rounded bg-green-500/10">
                  <svg
                    className="h-3.5 w-3.5 text-green-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    strokeWidth={2}
                  >
                    <polyline points="16,18 22,12 16,6" />
                    <polyline points="8,6 2,12 8,18" />
                  </svg>
                </div>
                <span className="text-sm font-medium text-foreground">
                  {cls.name}
                </span>
                <span className="rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
                  v{cls.apiVersion}
                </span>
              </div>
              <div className="flex items-center gap-3 pl-9 text-xs text-muted-foreground">
                <span>{cls.lengthWithoutComments} chars</span>
                <span>{cls.status}</span>
                <span>
                  Modified: {new Date(cls.lastModified).toLocaleDateString()}
                </span>
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
