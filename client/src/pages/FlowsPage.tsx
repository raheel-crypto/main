import { FlowList } from "../components/flows/FlowList";
import { useFlows } from "../hooks/useFlows";

export function FlowsPage() {
  const { data: flows, isLoading } = useFlows();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Flows</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Browse and analyze Salesforce flows with AI
        </p>
      </div>
      <FlowList flows={flows} isLoading={isLoading} />
    </div>
  );
}
