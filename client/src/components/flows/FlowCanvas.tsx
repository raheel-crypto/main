import { useMemo } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  type Node,
  type Edge,
  Position,
  MarkerType,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import dagre from "dagre";
import type { FlowElement } from "../../lib/api";
import { FlowNode } from "./FlowNode";

interface FlowCanvasProps {
  elements: FlowElement[];
}

const nodeTypes = { flowNode: FlowNode };

const typeColors: Record<string, string> = {
  Start: "#22c55e",
  Decision: "#eab308",
  RecordLookup: "#3b82f6",
  RecordCreate: "#10b981",
  RecordUpdate: "#f97316",
  RecordDelete: "#ef4444",
  Assignment: "#a855f7",
  Loop: "#06b6d4",
  Screen: "#ec4899",
  ActionCall: "#6366f1",
  Subflow: "#14b8a6",
};

const edgeColors: Record<string, string> = {
  Default: "#71717a",
  Fault: "#ef4444",
  "Each Item": "#06b6d4",
  "After Last": "#a855f7",
};

function buildGraph(elements: FlowElement[]): { nodes: Node[]; edges: Edge[] } {
  const g = new dagre.graphlib.Graph();
  g.setDefaultEdgeLabel(() => ({}));
  g.setGraph({
    rankdir: "TB",
    nodesep: 80,
    ranksep: 100,
    edgesep: 40,
    marginx: 20,
    marginy: 20,
  });

  const nodeNames = new Set(elements.map((el) => el.name));
  const nodes: Node[] = [];
  const edges: Edge[] = [];

  for (const el of elements) {
    const nodeHeight = el.type === "Decision" ? 90 : 80;
    g.setNode(el.name, { width: 280, height: nodeHeight });

    nodes.push({
      id: el.name,
      type: "flowNode",
      position: { x: 0, y: 0 },
      data: {
        label: el.label,
        type: el.type,
        description: el.description,
        color: typeColors[el.type] || "#71717a",
        branchCount: el.connectors.length,
      },
      sourcePosition: Position.Bottom,
      targetPosition: Position.Top,
    });

    // Add ALL edges from this element's connectors
    for (const conn of el.connectors) {
      if (!nodeNames.has(conn.target)) continue;

      const edgeColor = edgeColors[conn.label || ""] || "#52525b";
      const isFault = conn.label === "Fault";

      edges.push({
        id: `${el.name}-${conn.target}-${conn.label || "default"}`,
        source: el.name,
        target: conn.target,
        animated: el.type === "Loop" || isFault,
        label: conn.label || undefined,
        labelStyle: { fill: "#a1a1aa", fontSize: 10, fontWeight: 500 },
        labelBgStyle: { fill: "#09090b", fillOpacity: 0.8 },
        labelBgPadding: [4, 2] as [number, number],
        style: {
          stroke: edgeColor,
          strokeWidth: isFault ? 1.5 : 2,
          strokeDasharray: isFault ? "5,5" : undefined,
        },
        markerEnd: {
          type: MarkerType.ArrowClosed,
          color: edgeColor,
          width: 16,
          height: 16,
        },
      });

      g.setEdge(el.name, conn.target);
    }
  }

  dagre.layout(g);

  for (const node of nodes) {
    const pos = g.node(node.id);
    if (pos) {
      node.position = { x: pos.x - 140, y: pos.y - 40 };
    }
  }

  return { nodes, edges };
}

export function FlowCanvas({ elements }: FlowCanvasProps) {
  const { nodes, edges } = useMemo(() => buildGraph(elements), [elements]);

  if (elements.length === 0) {
    return (
      <div className="flex h-[500px] items-center justify-center rounded-lg border border-border text-sm text-muted-foreground">
        No flow elements to display
      </div>
    );
  }

  return (
    <div className="h-[700px] rounded-lg border border-border overflow-hidden">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.3, maxZoom: 1 }}
        minZoom={0.1}
        maxZoom={2}
        proOptions={{ hideAttribution: true }}
        defaultEdgeOptions={{
          type: "smoothstep",
        }}
      >
        <Background color="#27272a" gap={20} />
        <Controls
          className="!bg-card !border-border !shadow-none [&>button]:!bg-card [&>button]:!border-border [&>button]:!text-foreground [&>button:hover]:!bg-accent"
        />
        <MiniMap
          className="!bg-card !border-border"
          nodeColor={(n) => (n.data?.color as string) || "#71717a"}
          maskColor="rgba(0,0,0,0.5)"
        />
      </ReactFlow>
    </div>
  );
}
