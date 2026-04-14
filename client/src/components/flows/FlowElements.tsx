import { cn } from "../../lib/utils";
import type { FlowElement } from "../../lib/api";

interface FlowElementsProps {
  elements: FlowElement[];
}

const elementTypeConfig: Record<
  string,
  { color: string; icon: string; bg: string }
> = {
  Start: {
    color: "text-green-400",
    bg: "bg-green-500/10 border-green-500/20",
    icon: "play",
  },
  Decision: {
    color: "text-yellow-400",
    bg: "bg-yellow-500/10 border-yellow-500/20",
    icon: "split",
  },
  RecordLookup: {
    color: "text-blue-400",
    bg: "bg-blue-500/10 border-blue-500/20",
    icon: "search",
  },
  RecordCreate: {
    color: "text-emerald-400",
    bg: "bg-emerald-500/10 border-emerald-500/20",
    icon: "plus",
  },
  RecordUpdate: {
    color: "text-orange-400",
    bg: "bg-orange-500/10 border-orange-500/20",
    icon: "edit",
  },
  RecordDelete: {
    color: "text-red-400",
    bg: "bg-red-500/10 border-red-500/20",
    icon: "trash",
  },
  Assignment: {
    color: "text-purple-400",
    bg: "bg-purple-500/10 border-purple-500/20",
    icon: "assign",
  },
  Loop: {
    color: "text-cyan-400",
    bg: "bg-cyan-500/10 border-cyan-500/20",
    icon: "loop",
  },
  Screen: {
    color: "text-pink-400",
    bg: "bg-pink-500/10 border-pink-500/20",
    icon: "screen",
  },
  ActionCall: {
    color: "text-indigo-400",
    bg: "bg-indigo-500/10 border-indigo-500/20",
    icon: "action",
  },
  Subflow: {
    color: "text-teal-400",
    bg: "bg-teal-500/10 border-teal-500/20",
    icon: "subflow",
  },
};

export function FlowElements({ elements }: FlowElementsProps) {
  return (
    <div className="space-y-3">
      <h3 className="text-sm font-medium text-foreground">
        Flow Elements ({elements.length})
      </h3>
      <div className="space-y-2">
        {elements.map((element, idx) => (
          <ElementCard key={element.name} element={element} index={idx} />
        ))}
      </div>
    </div>
  );
}

function ElementCard({
  element,
  index,
}: {
  element: FlowElement;
  index: number;
}) {
  const config = elementTypeConfig[element.type] || {
    color: "text-muted-foreground",
    bg: "bg-muted border-border",
    icon: "default",
  };

  return (
    <div className={cn("rounded-lg border p-3", config.bg)}>
      <div className="flex items-start justify-between">
        <div className="space-y-1">
          <div className="flex items-center gap-2">
            <span className="text-xs font-mono text-muted-foreground">
              #{index + 1}
            </span>
            <span className={cn("text-xs font-medium", config.color)}>
              {element.type}
            </span>
          </div>
          <div className="text-sm font-medium text-foreground">
            {element.label}
          </div>
          {element.description && (
            <div className="text-xs text-muted-foreground">
              {element.description}
            </div>
          )}
        </div>
        {element.connector && (
          <div className="flex items-center gap-1 text-xs text-muted-foreground">
            <svg
              className="h-3 w-3"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path d="M5 12h14M12 5l7 7-7 7" />
            </svg>
            <span className="font-mono">{element.connector}</span>
          </div>
        )}
      </div>

      {/* Referenced fields */}
      {element.referencedFields.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1">
          {element.referencedFields.map((f) => (
            <span
              key={f}
              className="rounded bg-background/50 px-1.5 py-0.5 font-mono text-xs text-muted-foreground"
            >
              {f}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
