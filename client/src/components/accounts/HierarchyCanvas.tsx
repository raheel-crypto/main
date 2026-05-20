import { useMemo } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  Position,
  MarkerType,
  type Node,
  type Edge,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import dagre from "dagre";
import type { HierarchyNode } from "../../lib/api";
import { HierarchyAccountNode } from "./HierarchyAccountNode";

interface HierarchyCanvasProps {
  nodes: HierarchyNode[];
  resolvedGapIds?: Set<string>;
}

const nodeTypes = { account: HierarchyAccountNode };

const kindColors: Record<HierarchyNode["kind"], string> = {
  "ultimate-parent": "#22c55e",
  "regional-parent": "#3b82f6",
  child: "#a1a1aa",
  gap: "#f97316",
};

function buildGraph(
  hierarchyNodes: HierarchyNode[],
  resolvedGapIds: Set<string>
): { nodes: Node[]; edges: Edge[] } {
  const g = new dagre.graphlib.Graph();
  g.setDefaultEdgeLabel(() => ({}));
  g.setGraph({
    rankdir: "TB",
    nodesep: 60,
    ranksep: 120,
    edgesep: 30,
    marginx: 20,
    marginy: 20,
  });

  const nodeIds = new Set(hierarchyNodes.map((n) => n.id));
  const rfNodes: Node[] = [];
  const rfEdges: Edge[] = [];

  for (const n of hierarchyNodes) {
    g.setNode(n.id, { width: 260, height: 110 });
    const color = kindColors[n.kind] || "#71717a";
    rfNodes.push({
      id: n.id,
      type: "account",
      position: { x: 0, y: 0 },
      data: {
        name: n.name,
        kind: n.kind,
        billingCountry: n.billingCountry,
        website: n.website,
        rationale: n.rationale,
        isChange: n.isChange,
        accountId: n.accountId,
        color,
        resolved: n.kind === "gap" && resolvedGapIds.has(n.id),
      },
      sourcePosition: Position.Bottom,
      targetPosition: Position.Top,
    });

    if (n.parentNodeId && nodeIds.has(n.parentNodeId)) {
      const edgeColor = n.isChange ? "#22c55e" : "#52525b";
      rfEdges.push({
        id: `${n.id}-${n.parentNodeId}`,
        source: n.parentNodeId,
        target: n.id,
        animated: n.isChange,
        style: {
          stroke: edgeColor,
          strokeWidth: 2,
          strokeDasharray: n.isChange ? "6,4" : undefined,
        },
        markerEnd: {
          type: MarkerType.ArrowClosed,
          color: edgeColor,
          width: 14,
          height: 14,
        },
      });
      g.setEdge(n.parentNodeId, n.id);
    }
  }

  dagre.layout(g);
  for (const rfNode of rfNodes) {
    const pos = g.node(rfNode.id);
    if (pos) rfNode.position = { x: pos.x - 130, y: pos.y - 55 };
  }
  return { nodes: rfNodes, edges: rfEdges };
}

export function HierarchyCanvas({ nodes, resolvedGapIds }: HierarchyCanvasProps) {
  const resolved = resolvedGapIds || new Set<string>();
  const { nodes: rfNodes, edges: rfEdges } = useMemo(
    () => buildGraph(nodes, resolved),
    [nodes, resolved]
  );

  if (nodes.length === 0) {
    return (
      <div className="flex h-[500px] items-center justify-center rounded-lg border border-border text-sm text-muted-foreground">
        No hierarchy proposed yet.
      </div>
    );
  }

  return (
    <div className="h-[600px] rounded-lg border border-border overflow-hidden">
      <ReactFlow
        nodes={rfNodes}
        edges={rfEdges}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.3, maxZoom: 1 }}
        minZoom={0.1}
        maxZoom={2}
        proOptions={{ hideAttribution: true }}
        defaultEdgeOptions={{ type: "smoothstep" }}
      >
        <Background color="#27272a" gap={20} />
        <Controls className="!bg-card !border-border !shadow-none [&>button]:!bg-card [&>button]:!border-border [&>button]:!text-foreground [&>button:hover]:!bg-accent" />
        <MiniMap
          className="!bg-card !border-border"
          nodeColor={(n) => (n.data?.color as string) || "#71717a"}
          maskColor="rgba(0,0,0,0.5)"
        />
      </ReactFlow>
    </div>
  );
}
