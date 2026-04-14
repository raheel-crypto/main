import { useState } from "react";
import { Link } from "react-router-dom";
import { cn } from "../../lib/utils";
import type { FieldUsageTree as FieldUsageTreeType } from "../../lib/api";

interface UsageTreeProps {
  data: FieldUsageTreeType;
}

const categoryIcons: Record<string, string> = {
  "Page Layouts": "layout",
  Flows: "workflow",
  "Apex Classes": "code",
  "Apex Triggers": "zap",
  "Validation Rules": "shield",
  "Formula Fields": "calculator",
  Reports: "bar-chart",
  "Workflow Field Updates": "refresh",
  "Email Templates": "mail",
  "Lightning Pages": "monitor",
  "Quick Actions": "play",
};

const categoryColors: Record<string, string> = {
  "Page Layouts": "text-blue-400 bg-blue-500/10",
  Flows: "text-purple-400 bg-purple-500/10",
  "Apex Classes": "text-green-400 bg-green-500/10",
  "Apex Triggers": "text-yellow-400 bg-yellow-500/10",
  "Validation Rules": "text-red-400 bg-red-500/10",
  "Formula Fields": "text-orange-400 bg-orange-500/10",
  Reports: "text-cyan-400 bg-cyan-500/10",
};

export function UsageTree({ data }: UsageTreeProps) {
  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 rounded-lg border border-border bg-card p-3">
        <div className="flex h-8 w-8 items-center justify-center rounded-md bg-sf-blue/10">
          <svg
            className="h-4 w-4 text-sf-blue"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
          >
            <circle cx="12" cy="12" r="3" />
            <path d="M12 1v6m0 6v6m-7-7H1m22 0h-4" />
          </svg>
        </div>
        <div>
          <div className="text-sm font-medium text-foreground">
            {data.object}.{data.field}
          </div>
          <div className="text-xs text-muted-foreground">
            {data.totalReferences} total references
          </div>
        </div>
      </div>

      {data.categories.length === 0 ? (
        <div className="rounded-lg border border-border p-8 text-center text-sm text-muted-foreground">
          No references found for this field.
        </div>
      ) : (
        <div className="space-y-1 pl-4">
          {data.categories.map((cat) => (
            <CategoryNode key={cat.category} category={cat} />
          ))}
        </div>
      )}
    </div>
  );
}

function CategoryNode({
  category,
}: {
  category: { category: string; items: { type: string; name: string; id: string }[] };
}) {
  const [expanded, setExpanded] = useState(true);
  const colorClass =
    categoryColors[category.category] ||
    "text-muted-foreground bg-muted";

  return (
    <div>
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left transition-colors hover:bg-accent/50"
      >
        <svg
          className={cn(
            "h-3 w-3 text-muted-foreground transition-transform",
            expanded && "rotate-90"
          )}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <polyline points="9,18 15,12 9,6" />
        </svg>
        <span
          className={cn("rounded px-2 py-0.5 text-xs font-medium", colorClass)}
        >
          {category.category}
        </span>
        <span className="text-xs text-muted-foreground">
          ({category.items.length})
        </span>
      </button>

      {expanded && (
        <div className="ml-6 space-y-0.5 border-l border-border pl-3">
          {category.items.map((item) => (
            <ItemNode key={item.id} item={item} />
          ))}
        </div>
      )}
    </div>
  );
}

function ItemNode({ item }: { item: { type: string; name: string; id: string } }) {
  const link = getItemLink(item);

  return (
    <div className="flex items-center gap-2 rounded px-3 py-1.5 hover:bg-accent/30">
      <div className="h-1.5 w-1.5 rounded-full bg-muted-foreground" />
      {link ? (
        <Link
          to={link}
          className="text-sm text-primary hover:underline"
        >
          {item.name}
        </Link>
      ) : (
        <span className="text-sm text-foreground">{item.name}</span>
      )}
    </div>
  );
}

function getItemLink(item: { type: string; name: string; id: string }): string | null {
  switch (item.type) {
    case "Flow":
      return `/flows/${item.id}`;
    case "ApexClass":
      return `/apex/${item.id}`;
    default:
      return null;
  }
}
