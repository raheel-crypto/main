import { memo } from "react";
import { Handle, Position, type NodeProps } from "@xyflow/react";

interface FlowNodeData {
  label: string;
  type: string;
  description: string | null;
  color: string;
}

export const FlowNode = memo(function FlowNode({
  data,
}: NodeProps & { data: FlowNodeData }) {
  const { label, type, description, color } = data as FlowNodeData;

  return (
    <div
      className="min-w-[240px] rounded-lg border bg-card shadow-lg"
      style={{ borderColor: color + "40" }}
    >
      <Handle type="target" position={Position.Top} className="!bg-muted-foreground !w-2 !h-2" />

      <div
        className="flex items-center gap-2 rounded-t-lg px-3 py-1.5"
        style={{ backgroundColor: color + "15" }}
      >
        <div
          className="h-2 w-2 rounded-full"
          style={{ backgroundColor: color }}
        />
        <span className="text-xs font-medium" style={{ color }}>
          {type}
        </span>
      </div>

      <div className="px-3 py-2">
        <div className="text-sm font-medium text-foreground">{label}</div>
        {description && (
          <div className="mt-0.5 text-xs text-muted-foreground line-clamp-2">
            {description}
          </div>
        )}
      </div>

      <Handle type="source" position={Position.Bottom} className="!bg-muted-foreground !w-2 !h-2" />
    </div>
  );
});
