import type { AIExplanation } from "../../lib/api";

interface ApexAIExplanationProps {
  explanation: AIExplanation | null;
  isLoading: boolean;
  onExplain: () => void;
}

export function ApexAIExplanation({
  explanation,
  isLoading,
  onExplain,
}: ApexAIExplanationProps) {
  if (!explanation && !isLoading) {
    return (
      <div className="rounded-lg border border-border bg-card p-4">
        <div className="flex items-center justify-between">
          <div className="space-y-1">
            <h3 className="text-sm font-medium text-foreground">
              AI Analysis
            </h3>
            <p className="text-xs text-muted-foreground">
              Get an AI-powered explanation of what this Apex class does
            </p>
          </div>
          <button
            onClick={onExplain}
            className="flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            <svg
              className="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            Explain with AI
          </button>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="rounded-lg border border-border bg-card p-4">
        <div className="flex items-center gap-2">
          <div className="h-4 w-4 animate-spin rounded-full border-2 border-primary border-t-transparent" />
          <span className="text-sm text-muted-foreground">
            Analyzing Apex class with AI...
          </span>
        </div>
      </div>
    );
  }

  if (!explanation) return null;

  return (
    <div className="space-y-4 rounded-lg border border-border bg-card p-4">
      <h3 className="text-sm font-medium text-foreground">AI Analysis</h3>

      {/* Summary */}
      <div className="rounded-lg bg-primary/5 p-3">
        <div className="text-xs font-medium uppercase tracking-wider text-primary">
          Summary
        </div>
        <p className="mt-1 text-sm text-foreground">{explanation.summary}</p>
      </div>

      {/* Details */}
      <div>
        <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
          Detailed Analysis
        </div>
        <div className="mt-1 whitespace-pre-wrap text-sm text-foreground">
          {explanation.details}
        </div>
      </div>

      {/* Objects & Fields */}
      {explanation.objectsAndFields.length > 0 && (
        <div>
          <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
            Objects & Fields
          </div>
          <div className="mt-2 space-y-2">
            {explanation.objectsAndFields.map((of) => (
              <div key={of.object}>
                <span className="text-sm font-medium text-sf-blue">
                  {of.object}
                </span>
                <div className="ml-4 flex flex-wrap gap-1">
                  {of.fields.map((f) => (
                    <span
                      key={f}
                      className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs text-muted-foreground"
                    >
                      {f}
                    </span>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Suggestions */}
      {explanation.suggestions.length > 0 && (
        <div>
          <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
            Suggestions
          </div>
          <ul className="mt-2 space-y-1">
            {explanation.suggestions.map((s, i) => (
              <li
                key={i}
                className="flex items-start gap-2 text-sm text-foreground"
              >
                <svg
                  className="mt-0.5 h-4 w-4 shrink-0 text-yellow-400"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  strokeWidth={2}
                >
                  <circle cx="12" cy="12" r="10" />
                  <line x1="12" y1="8" x2="12" y2="12" />
                  <line x1="12" y1="16" x2="12.01" y2="16" />
                </svg>
                {s}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
