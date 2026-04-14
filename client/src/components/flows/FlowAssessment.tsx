import { cn } from "../../lib/utils";
import type { AIExplanation } from "../../lib/api";

interface FlowAssessmentProps {
  assessment: AIExplanation | null;
  isLoading: boolean;
  onAssess: () => void;
}

export function FlowAssessment({
  assessment,
  isLoading,
  onAssess,
}: FlowAssessmentProps) {
  if (!assessment && !isLoading) {
    return (
      <div className="rounded-lg border border-amber-500/20 bg-amber-500/5 p-4">
        <div className="flex items-center justify-between">
          <div className="space-y-1">
            <h3 className="text-sm font-medium text-foreground">
              Well-Architected Assessment
            </h3>
            <p className="text-xs text-muted-foreground">
              Evaluate this flow against Salesforce&apos;s Well-Architected Framework
              and official best practices
            </p>
          </div>
          <button
            onClick={onAssess}
            className="flex items-center gap-2 rounded-lg bg-amber-500 px-4 py-2 text-sm font-medium text-black transition-colors hover:bg-amber-400"
          >
            <svg
              className="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
            </svg>
            Assess Architecture
          </button>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="rounded-lg border border-amber-500/20 bg-amber-500/5 p-4">
        <div className="flex items-center gap-2">
          <div className="h-4 w-4 animate-spin rounded-full border-2 border-amber-500 border-t-transparent" />
          <span className="text-sm text-muted-foreground">
            Assessing flow against Well-Architected Framework...
          </span>
        </div>
      </div>
    );
  }

  if (!assessment) return null;

  return (
    <div className="space-y-4 rounded-lg border border-amber-500/20 bg-amber-500/5 p-4">
      <div className="flex items-center gap-2">
        <svg
          className="h-5 w-5 text-amber-500"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
        </svg>
        <h3 className="text-sm font-medium text-foreground">
          Well-Architected Assessment
        </h3>
      </div>

      {/* Summary */}
      <div className="rounded-lg bg-background/50 p-3">
        <div className="text-xs font-medium uppercase tracking-wider text-amber-500">
          Overall Assessment
        </div>
        <p className="mt-1 text-sm text-foreground">{assessment.summary}</p>
      </div>

      {/* Pillar findings */}
      {assessment.objectsAndFields.length > 0 && (
        <div className="space-y-3">
          <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
            Assessment by Pillar
          </div>
          {assessment.objectsAndFields.map((pillar) => (
            <PillarCard
              key={pillar.object}
              name={pillar.object}
              findings={pillar.fields}
            />
          ))}
        </div>
      )}

      {/* Detailed analysis */}
      <div>
        <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
          Detailed Analysis
        </div>
        <div className="mt-1 whitespace-pre-wrap text-sm text-foreground">
          {assessment.details}
        </div>
      </div>

      {/* Actionable steps */}
      {assessment.suggestions.length > 0 && (
        <div>
          <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
            Remediation Steps
          </div>
          <div className="mt-2 space-y-2">
            {assessment.suggestions.map((s, i) => (
              <div
                key={i}
                className="flex items-start gap-3 rounded-lg bg-background/50 p-3"
              >
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-amber-500/20 text-xs font-bold text-amber-500">
                  {i + 1}
                </span>
                <span className="text-sm text-foreground">{s}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

const pillarColors: Record<string, { border: string; bg: string; text: string }> = {
  Trusted: { border: "border-blue-500/20", bg: "bg-blue-500/10", text: "text-blue-400" },
  Easy: { border: "border-green-500/20", bg: "bg-green-500/10", text: "text-green-400" },
  Adaptable: { border: "border-purple-500/20", bg: "bg-purple-500/10", text: "text-purple-400" },
};

function PillarCard({ name, findings }: { name: string; findings: string[] }) {
  const colors = pillarColors[name] || {
    border: "border-border",
    bg: "bg-muted",
    text: "text-muted-foreground",
  };

  return (
    <div className={cn("rounded-lg border p-3", colors.border)}>
      <div className={cn("text-xs font-semibold uppercase tracking-wider", colors.text)}>
        {name}
      </div>
      <ul className="mt-2 space-y-1">
        {findings.map((f, i) => (
          <li key={i} className="flex items-start gap-2 text-xs text-foreground">
            <span className={cn("mt-1 h-1.5 w-1.5 shrink-0 rounded-full", colors.bg.replace("/10", ""))} />
            {f}
          </li>
        ))}
      </ul>
    </div>
  );
}
