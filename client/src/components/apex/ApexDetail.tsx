import { ApexSourceView } from "./ApexSourceView";
import { ApexAIExplanation } from "./ApexAIExplanation";
import type { ApexDetail as ApexDetailType, AIExplanation } from "../../lib/api";

interface ApexDetailProps {
  apex: ApexDetailType;
  explanation: AIExplanation | null;
  isExplaining: boolean;
  onExplain: () => void;
}

export function ApexDetailView({
  apex,
  explanation,
  isExplaining,
  onExplain,
}: ApexDetailProps) {
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="space-y-2">
        <div className="flex items-center gap-3">
          <h2 className="text-xl font-bold text-foreground">{apex.name}</h2>
          <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
            v{apex.apiVersion}
          </span>
          {apex.isTest && (
            <span className="rounded bg-yellow-500/10 px-2 py-0.5 text-xs text-yellow-400">
              Test Class
            </span>
          )}
          {apex.isTrigger && (
            <span className="rounded bg-orange-500/10 px-2 py-0.5 text-xs text-orange-400">
              Trigger
            </span>
          )}
        </div>
        <div className="flex items-center gap-4 text-xs text-muted-foreground">
          <span>Status: {apex.status}</span>
          <span>
            Modified: {new Date(apex.lastModified).toLocaleDateString()}
          </span>
          <span>{apex.body.split("\n").length} lines</span>
        </div>
      </div>

      {/* AI Explanation */}
      <ApexAIExplanation
        explanation={explanation}
        isLoading={isExplaining}
        onExplain={onExplain}
      />

      <div className="grid grid-cols-3 gap-6">
        {/* Source code */}
        <div className="col-span-2">
          <ApexSourceView source={apex.body} />
        </div>

        {/* Metadata sidebar */}
        <div className="space-y-4">
          {/* Annotations */}
          {apex.annotations.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                Annotations
              </h3>
              <div className="space-y-1">
                {apex.annotations.map((a, i) => (
                  <div key={i} className="font-mono text-xs text-purple-400">
                    {a}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* SOQL Queries */}
          {apex.soqlQueries.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                SOQL Queries ({apex.soqlQueries.length})
              </h3>
              <div className="space-y-2">
                {apex.soqlQueries.map((q, i) => (
                  <pre
                    key={i}
                    className="overflow-x-auto rounded bg-muted p-2 font-mono text-xs text-foreground"
                  >
                    {q}
                  </pre>
                ))}
              </div>
            </div>
          )}

          {/* DML Operations */}
          {apex.dmlOperations.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                DML Operations
              </h3>
              <div className="flex flex-wrap gap-1">
                {apex.dmlOperations.map((d, i) => (
                  <span
                    key={i}
                    className="rounded bg-orange-500/10 px-2 py-0.5 text-xs text-orange-400"
                  >
                    {d}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Referenced Objects */}
          {apex.referencedObjects.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                Referenced Objects
              </h3>
              <div className="flex flex-wrap gap-1">
                {apex.referencedObjects.map((obj) => (
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
          {apex.referencedFields.length > 0 && (
            <div className="rounded-lg border border-border p-4">
              <h3 className="mb-2 text-sm font-medium text-foreground">
                Referenced Fields
              </h3>
              <div className="space-y-0.5">
                {apex.referencedFields.map((f) => (
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
