import { useParams, Link } from "react-router-dom";
import { ApexDetailView } from "../components/apex/ApexDetail";
import { useApexDetail, useApexExplanation } from "../hooks/useApex";

export function ApexDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: apex, isLoading, error } = useApexDetail(id);
  const {
    data: explanation,
    isLoading: isExplaining,
    explain,
  } = useApexExplanation();

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-64 animate-pulse rounded bg-muted" />
        <div className="h-48 animate-pulse rounded-lg bg-muted" />
      </div>
    );
  }

  if (error || !apex) {
    return (
      <div className="py-12 text-center">
        <p className="text-sm text-destructive">
          {error || "Apex class not found"}
        </p>
        <Link to="/apex" className="mt-2 text-sm text-primary hover:underline">
          Back to Apex Classes
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2">
        <Link
          to="/apex"
          className="text-sm text-muted-foreground hover:text-foreground"
        >
          Apex Classes
        </Link>
        <span className="text-muted-foreground">/</span>
        <span className="text-sm font-medium text-foreground">{apex.name}</span>
      </div>

      <ApexDetailView
        apex={apex}
        explanation={explanation}
        isExplaining={isExplaining}
        onExplain={() => explain(id!)}
      />
    </div>
  );
}
