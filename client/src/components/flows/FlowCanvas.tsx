import { useMemo } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  type Node,
  type Edge,
  Position,
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

function buildGraph(elements: FlowElement[]): { nodes: Node[]; edges: Edge[] } {
  const g = new dagre.graphlib.Graph();
  g.setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: "TB", nodesep: 60, ranksep: 80 });

  const nodes: Node[] = [];
  const edges: Edge[] = [];

  for (const el of elements) {
    g.setNode(el.name, { width: 260, height: 80 });

    nodes.push({
      id: el.name,
      type: "flowNode",
      position: { x: 0, y: 0 },
      data: {
        label: el.label,
        type: el.type,
        description: el.description,
        color: typeColors[el.type] || "#71717a",
      },
      sourcePosition: Position.Bottom,
      targetPosition: Position.Top,
    });

    if (el.connector) {
      edges.push({
        id: `${el.name}-${el.connector}`,
        source: el.name,
        target: el.connector,
        animated: el.type === "Loop",
        style: { stroke: "#52525b", strokeWidth: 2 },
      });
    }
  }

  dagre.layout(g);

  for (const node of nodes) {
    const pos = g.node(node.id);
    if (pos) {
      node.position = { x: pos.x - 130, y: pos.y - 40 };
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
    <div className="h-[600px] rounded-lg border border-border overflow-hidden">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.2 }}
        minZoom={0.3}
        maxZoom={1.5}
        proOptions={{ hideAttribution: true }}
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
