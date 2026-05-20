import { memo } from "react";
import { Handle, Position, type NodeProps } from "@xyflow/react";

interface HierarchyNodeData {
  name: string;
  kind: "ultimate-parent" | "regional-parent" | "child" | "gap";
  billingCountry: string | null;
  website: string | null;
  rationale: string;
  isChange: boolean;
  accountId: string | null;
  color: string;
  resolved: boolean;
}

const kindLabel: Record<HierarchyNodeData["kind"], string> = {
  "ultimate-parent": "Ultimate Parent",
  "regional-parent": "Regional Parent",
  child: "Child Account",
  gap: "Gap — Needs Creating",
};

export const HierarchyAccountNode = memo(function HierarchyAccountNode({
  data,
}: NodeProps & { data: HierarchyNodeData }) {
  const { name, kind, billingCountry, website, isChange, color, resolved } = data;
  const showResolvedBadge = kind === "gap" && resolved;

  return (
    <div
      className="min-w-[240px] rounded-lg border bg-card shadow-lg"
      style={{
        borderColor: color + (kind === "gap" && !resolved ? "" : "40"),
        borderStyle: kind === "gap" && !resolved ? "dashed" : "solid",
        borderWidth: kind === "gap" && !resolved ? 2 : 1,
      }}
    >
      <Handle type="target" position={Position.Top} className="!bg-muted-foreground !w-2 !h-2" />

      <div
        className="flex items-center justify-between gap-2 rounded-t-lg px-3 py-1.5"
        style={{ backgroundColor: color + "15" }}
      >
        <div className="flex items-center gap-2">
          <div className="h-2 w-2 rounded-full" style={{ backgroundColor: color }} />
          <span className="text-xs font-medium" style={{ color }}>
            {kindLabel[kind]}
          </span>
        </div>
        {isChange && (
          <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-[10px] font-medium text-green-400">
            CHANGE
          </span>
        )}
        {showResolvedBadge && (
          <span className="rounded bg-blue-500/15 px-1.5 py-0.5 text-[10px] font-medium text-blue-400">
            CREATED
          </span>
        )}
      </div>

      <div className="space-y-1 px-3 py-2">
        <div className="text-sm font-medium text-foreground">{name}</div>
        {billingCountry && (
          <div className="text-xs text-muted-foreground">{billingCountry}</div>
        )}
        {website && (
          <div className="truncate text-[11px] text-muted-foreground/80">{website}</div>
        )}
      </div>

      <Handle type="source" position={Position.Bottom} className="!bg-muted-foreground !w-2 !h-2" />
    </div>
  );
});
