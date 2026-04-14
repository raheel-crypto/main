import { FlowElements } from "./FlowElements";
import { FlowAIExplanation } from "./FlowAIExplanation";
import type { FlowDetail as FlowDetailType, AIExplanation } from "../../lib/api";

interface FlowDetailProps {
  flow: FlowDetailType;
  explanation: AIExplanation | null;
  isExplaining: boolean;
  onExplain: () => void;
}

export function FlowDetailView({
  flow,
  explanation,
  isExplaining,
  onExplain,
}: FlowDetailProps) {
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="space-y-2">
        <div className="flex items-center gap-3">
          <h2 className="text-xl font-bold text-foreground">{flow.label}</h2>
          <span className="rounded-full bg-green-500/10 px-2 py-0.5 text-xs font-medium text-green-400">
            {flow.status}
          </span>
        </div>
        <div className="flex items-center gap-4 text-sm text-muted-foreground">
          <span>Type: {flow.type}</span>
          {flow.triggerObject && (
            <span>
              Trigger: {flow.triggerObject}
              {flow.triggerType && ` (${flow.triggerType})`}
            </span>
          )}
          <span>{flow.elements.length} elements</span>
        </div>
        {flow.description && (
          <p className="text-sm text-muted-foreground">{flow.description}</p>
        )}
      </div>

      {/* AI Explanation */}
      <FlowAIExplanation
        explanation={explanation}
        isLoading={isExplaining}
        onExplain={onExplain}
      />

      <div className="grid grid-cols-3 gap-6">
        {/* Flow Elements */}
        <div className="col-span-2">
          <FlowElements elements={flow.elements} />
        </div>

        {/* Metadata sidebar */}
        <div className="space-y-4">
          {/* Variables */}
          {flow.variables.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                Variables ({flow.variables.length})
              </h3>
              <div className="space-y-1">
                {flow.variables.map((v) => (
                  <div key={v.name} className="text-xs">
                    <span className="font-mono text-foreground">{v.name}</span>
                    <span className="ml-2 text-muted-foreground">
                      {v.dataType}
                    </span>
                    {v.isInput && (
                      <span className="ml-1 rounded bg-blue-500/10 px-1 text-blue-400">
                        in
                      </span>
                    )}
                    {v.isOutput && (
                      <span className="ml-1 rounded bg-green-500/10 px-1 text-green-400">
                        out
                      </span>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Referenced Objects */}
          {flow.referencedObjects.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                Referenced Objects
              </h3>
              <div className="flex flex-wrap gap-1">
                {flow.referencedObjects.map((obj) => (
                  <span
                    key={obj}
                    className="rounded bg-sf-blue/10 px-2 py-0.5 text-xs text-sf-blue"
                  >
                    {obj}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Referenced Fields */}
          {flow.referencedFields.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                Referenced Fields
              </h3>
              <div className="space-y-0.5">
                {flow.referencedFields.map((f) => (
                  <div
                    key={f}
                    className="font-mono text-xs text-muted-foreground"
                  >
                    {f}
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
