import { useState } from "react";
import { Link } from "react-router-dom";
import { cn } from "../../lib/utils";
import type { SFObject } from "../../lib/api";

interface ObjectListProps {
  objects: SFObject[];
  isLoading: boolean;
}

export function ObjectList({ objects, isLoading }: ObjectListProps) {
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<"all" | "custom" | "standard">("all");

  const filtered = objects.filter((obj) => {
    const matchesSearch =
      obj.name.toLowerCase().includes(search.toLowerCase()) ||
      obj.label.toLowerCase().includes(search.toLowerCase());
    const matchesFilter =
      filter === "all" ||
      (filter === "custom" && obj.custom) ||
      (filter === "standard" && !obj.custom);
    return matchesSearch && matchesFilter;
  });

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 8 }).map((_, i) => (
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
      <div className="flex items-center gap-3">
        <input
          type="text"
          placeholder="Search objects..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="flex-1 rounded-lg border border-input bg-background px-4 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        />
        <div className="flex rounded-lg border border-input">
          {(["all", "custom", "standard"] as const).map((f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className={cn(
                "px-3 py-2 text-xs font-medium capitalize transition-colors",
                filter === f
                  ? "bg-accent text-accent-foreground"
                  : "text-muted-foreground hover:text-foreground"
              )}
            >
              {f}
            </button>
          ))}
        </div>
      </div>

      <div className="text-xs text-muted-foreground">
        {filtered.length} objects
      </div>

      <div className="space-y-1">
        {filtered.map((obj) => (
          <Link
            key={obj.name}
            to={`/objects/${obj.name}`}
            className="flex items-center justify-between rounded-lg border border-transparent px-4 py-3 transition-colors hover:border-border hover:bg-accent/50"
          >
            <div className="flex items-center gap-3">
              <div
                className={cn(
                  "flex h-8 w-8 items-center justify-center rounded-md text-xs font-bold",
                  obj.custom
                    ? "bg-purple-500/10 text-purple-400"
                    : "bg-sf-blue/10 text-sf-blue"
                )}
              >
                {obj.custom ? "C" : "S"}
              </div>
              <div>
                <div className="text-sm font-medium text-foreground">
                  {obj.label}
                </div>
                <div className="text-xs text-muted-foreground">{obj.name}</div>
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
