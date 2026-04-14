import { useParams, Link } from "react-router-dom";
import { ObjectOverview } from "../components/objects/ObjectOverview";
import { useObjectDetail, useObjectAutomations } from "../hooks/useObjects";

export function ObjectDetailPage() {
  const { name } = useParams<{ name: string }>();
  const { data: detail, isLoading, error } = useObjectDetail(name);
  const { data: automations } = useObjectAutomations(name);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-48 animate-pulse rounded bg-muted" />
        <div className="grid grid-cols-4 gap-4">
          {Array.from({ length: 4 }).map((_, i) => (
            <div key={i} className="h-20 animate-pulse rounded-lg bg-muted" />
          ))}
        </div>
      </div>
    );
  }

  if (error || !detail) {
    return (
      <div className="py-12 text-center">
        <p className="text-sm text-destructive">
          {error || "Object not found"}
        </p>
        <Link to="/objects" className="mt-2 text-sm text-primary hover:underline">
          Back to Objects
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2">
        <Link
          to="/objects"
          className="text-sm text-muted-foreground hover:text-foreground"
        >
          Objects
        </Link>
        <span className="text-muted-foreground">/</span>
        <span className="text-sm font-medium text-foreground">
          {detail.label}
        </span>
        {detail.custom && (
          <span className="rounded bg-purple-500/10 px-2 py-0.5 text-xs text-purple-400">
            Custom
          </span>
        )}
      </div>

      <div>
        <h1 className="text-2xl font-bold text-foreground">{detail.label}</h1>
        <p className="text-sm font-mono text-muted-foreground">{detail.name}</p>
      </div>

      <ObjectOverview detail={detail} automations={automations} />
    </div>
  );
}
