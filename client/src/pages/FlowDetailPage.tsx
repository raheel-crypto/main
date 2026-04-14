import { useParams, Link } from "react-router-dom";
import { FlowDetailView } from "../components/flows/FlowDetail";
import { useFlowDetail, useFlowExplanation } from "../hooks/useFlows";

export function FlowDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: flow, isLoading, error } = useFlowDetail(id);
  const {
    data: explanation,
    isLoading: isExplaining,
    explain,
  } = useFlowExplanation();

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-64 animate-pulse rounded bg-muted" />
        <div className="h-32 animate-pulse rounded-lg bg-muted" />
      </div>
    );
  }

  if (error || !flow) {
    return (
      <div className="py-12 text-center">
        <p className="text-sm text-destructive">
          {error || "Flow not found"}
        </p>
        <Link to="/flows" className="mt-2 text-sm text-primary hover:underline">
          Back to Flows
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2">
        <Link
          to="/flows"
          className="text-sm text-muted-foreground hover:text-foreground"
        >
          Flows
        </Link>
        <span className="text-muted-foreground">/</span>
        <span className="text-sm font-medium text-foreground">
          {flow.label}
        </span>
      </div>

      <FlowDetailView
        flow={flow}
        explanation={explanation}
        isExplaining={isExplaining}
        onExplain={() => explain(id!)}
      />
    </div>
  );
}
