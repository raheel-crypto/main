import { useState } from "react";
import { cn } from "../../lib/utils";
import { FlowCanvas } from "./FlowCanvas";
import { FlowElements } from "./FlowElements";
import { FlowAIExplanation } from "./FlowAIExplanation";
import { FlowAssessment } from "./FlowAssessment";
import type { FlowDetail as FlowDetailType, AIExplanation } from "../../lib/api";

interface FlowDetailProps {
  flow: FlowDetailType;
  explanation: AIExplanation | null;
  isExplaining: boolean;
  onExplain: () => void;
  assessment: AIExplanation | null;
  isAssessing: boolean;
  onAssess: () => void;
}

type ViewMode = "diagram" | "elements";

export function FlowDetailView({
  flow,
  explanation,
  isExplaining,
  onExplain,
  assessment,
  isAssessing,
  onAssess,
}: FlowDetailProps) {
  const [viewMode, setViewMode] = useState<ViewMode>("diagram");

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

      {/* AI buttons row */}
      <div className="flex gap-3">
        <FlowAIExplanation
          explanation={explanation}
          isLoading={isExplaining}
          onExplain={onExplain}
        />
        <FlowAssessment
          assessment={assessment}
          isLoading={isAssessing}
          onAssess={onAssess}
        />
      </div>

      {/* View toggle */}
      <div className="flex items-center gap-2">
        <span className="text-xs text-muted-foreground">View:</span>
        <div className="flex rounded-lg border border-input">
          <button
            onClick={() => setViewMode("diagram")}
            className={cn(
              "flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium transition-colors",
              viewMode === "diagram"
                ? "bg-accent text-accent-foreground"
                : "text-muted-foreground hover:text-foreground"
            )}
          >
            <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <rect x="3" y="3" width="6" height="6" rx="1" />
              <rect x="15" y="3" width="6" height="6" rx="1" />
              <rect x="9" y="15" width="6" height="6" rx="1" />
              <path d="M6 9v3h6m6-6v3H12m0 0v6" />
            </svg>
            Diagram
          </button>
          <button
            onClick={() => setViewMode("elements")}
            className={cn(
              "flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium transition-colors",
              viewMode === "elements"
                ? "bg-accent text-accent-foreground"
                : "text-muted-foreground hover:text-foreground"
            )}
          >
            <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <line x1="8" y1="6" x2="21" y2="6" />
              <line x1="8" y1="12" x2="21" y2="12" />
              <line x1="8" y1="18" x2="21" y2="18" />
              <line x1="3" y1="6" x2="3.01" y2="6" />
              <line x1="3" y1="12" x2="3.01" y2="12" />
              <line x1="3" y1="18" x2="3.01" y2="18" />
            </svg>
            List
          </button>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-6">
        {/* Main content */}
        <div className="col-span-2">
          {viewMode === "diagram" ? (
            <FlowCanvas elements={flow.elements} />
          ) : (
            <FlowElements elements={flow.elements} />
          )}
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
