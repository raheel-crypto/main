import { Connection } from "jsforce";
import type { FlowDetailParsed, FlowElementParsed } from "../types/index.js";

export async function listFlows(conn: Connection) {
  // Query Flow directly -- most reliable across all org types
  // Get the latest version of each flow
  const query = `
    SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType, Status,
           VersionNumber, Description
    FROM Flow
    ORDER BY MasterLabel
  `;

  console.log("[flows] Listing flows via Flow object...");

  const result = await conn.tooling.query<{
    Id: string;
    Definition: { DeveloperName: string } | null;
    MasterLabel: string;
    ProcessType: string;
    Status: string;
    VersionNumber: number;
    Description: string | null;
  }>(query);

  console.log(`[flows] Found ${result.records?.length || 0} flow versions`);

  // Deduplicate: keep only the highest version per flow name
  const flowMap = new Map<string, (typeof result.records)[0]>();
  for (const f of result.records || []) {
    const key = f.Definition?.DeveloperName || f.MasterLabel;
    const existing = flowMap.get(key);
    if (!existing || f.VersionNumber > existing.VersionNumber) {
      flowMap.set(key, f);
    }
  }

  return Array.from(flowMap.values()).map((f) => ({
    id: f.Id,
    name: f.Definition?.DeveloperName || f.MasterLabel,
    label: f.MasterLabel,
    type: f.ProcessType,
    status: f.Status,
    triggerObject: null as string | null,
    triggerType: null as string | null,
    lastModified: "",
  }));
}

export async function getFlowDetail(
  conn: Connection,
  flowId: string
): Promise<FlowDetailParsed> {
  console.log(`[flows] Getting flow detail for: ${flowId}`);

  interface FlowRecord {
    Id: string;
    Definition: { DeveloperName: string } | null;
    MasterLabel: string;
    ProcessType: string;
    Status: string;
    Metadata: any;
  }

  // Try querying Flow by Id first
  let flow: FlowRecord | null = null;

  try {
    const query = `
      SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType,
             Status, Metadata
      FROM Flow
      WHERE Id = '${flowId}'
    `;
    const result = await conn.tooling.query<FlowRecord>(query);
    flow = result.records?.[0] || null;
  } catch (err) {
    console.log(`[flows] Direct query failed:`, err);
  }

  // If that didn't work, maybe flowId is a FlowDefinition Id
  if (!flow) {
    try {
      const defQuery = `
        SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType,
               Status, Metadata
        FROM Flow
        WHERE DefinitionId = '${flowId}'
        ORDER BY VersionNumber DESC
        LIMIT 1
      `;
      const result = await conn.tooling.query<FlowRecord>(defQuery);
      flow = result.records?.[0] || null;
    } catch (err) {
      console.log(`[flows] Definition query failed:`, err);
    }
  }

  if (!flow) {
    throw new Error(`Flow not found: ${flowId}`);
  }

  console.log(`[flows] Found flow: ${flow.MasterLabel}`);

  const metadata = flow.Metadata || {};
  const elements = parseFlowElements(metadata);
  const variables = parseFlowVariables(metadata);

  const referencedObjects = new Set<string>();
  const referencedFields = new Set<string>();

  for (const el of elements) {
    el.referencedObjects.forEach((o) => referencedObjects.add(o));
    el.referencedFields.forEach((f) => referencedFields.add(f));
  }

  return {
    id: flow.Id,
    name: flow.Definition?.DeveloperName || "",
    label: flow.MasterLabel,
    type: flow.ProcessType,
    status: flow.Status,
    triggerObject: metadata.start?.object || null,
    triggerType: metadata.start?.triggerType || null,
    description: metadata.description || null,
    elements,
    variables,
    referencedObjects: Array.from(referencedObjects),
    referencedFields: Array.from(referencedFields),
  };
}

function parseFlowElements(metadata: any): FlowElementParsed[] {
  const elements: FlowElementParsed[] = [];

  if (metadata.start) {
    const startConnector = metadata.start.connector?.targetReference || null;
    elements.push({
      name: "start",
      type: "Start",
      label: "Start",
      description: metadata.start.triggerType
        ? `Triggered by: ${metadata.start.triggerType} on ${metadata.start.object || "N/A"}`
        : "Flow start",
      referencedFields: extractFieldRefs(metadata.start),
      referencedObjects: metadata.start.object ? [metadata.start.object] : [],
      connector: startConnector,
      connectors: startConnector ? [{ target: startConnector, label: null }] : [],
    });
  }

  // Decisions need special handling for multiple outcome paths
  for (const d of metadata.decisions || []) {
    const connectors: { target: string; label: string | null }[] = [];

    // Default outcome
    if (d.defaultConnector?.targetReference) {
      connectors.push({ target: d.defaultConnector.targetReference, label: "Default" });
    }

    // Decision rules (outcome branches)
    for (const rule of d.rules || []) {
      if (rule.connector?.targetReference) {
        connectors.push({
          target: rule.connector.targetReference,
          label: rule.label || rule.name || null,
        });
      }
    }

    elements.push({
      name: d.name,
      type: "Decision",
      label: d.label || d.name,
      description: d.description || `${connectors.length} outcome(s)`,
      referencedFields: extractFieldRefs(d),
      referencedObjects: extractObjectRefs(d),
      connector: connectors[0]?.target || null,
      connectors,
    });
  }

  // Loops have two paths: next iteration and after loop
  for (const l of metadata.loops || []) {
    const connectors: { target: string; label: string | null }[] = [];
    if (l.nextValueConnector?.targetReference) {
      connectors.push({ target: l.nextValueConnector.targetReference, label: "Each Item" });
    }
    if (l.noMoreValuesConnector?.targetReference) {
      connectors.push({ target: l.noMoreValuesConnector.targetReference, label: "After Last" });
    }

    elements.push({
      name: l.name,
      type: "Loop",
      label: l.label || l.name,
      description: l.description || "Loop through collection",
      referencedFields: extractFieldRefs(l),
      referencedObjects: extractObjectRefs(l),
      connector: connectors[0]?.target || null,
      connectors,
    });
  }

  // All other element types: single connector path (+ optional fault path)
  const simpleTypes: {
    key: string;
    type: string;
    descFn?: (el: any) => string;
  }[] = [
    { key: "recordLookups", type: "RecordLookup", descFn: (r) => `Get records from ${r.object || "Unknown"}` },
    { key: "recordCreates", type: "RecordCreate", descFn: (r) => `Create ${r.object || "Unknown"} record` },
    { key: "recordUpdates", type: "RecordUpdate", descFn: (r) => `Update ${r.object || "Unknown"} record` },
    { key: "recordDeletes", type: "RecordDelete", descFn: (r) => `Delete ${r.object || "Unknown"} record` },
    { key: "assignments", type: "Assignment" },
    { key: "screens", type: "Screen" },
    { key: "actionCalls", type: "ActionCall", descFn: (a) => `Action: ${a.actionName || a.actionType || "Unknown"}` },
    { key: "subflows", type: "Subflow", descFn: (s) => `Subflow: ${s.flowName || "Unknown"}` },
  ];

  for (const { key, type, descFn } of simpleTypes) {
    for (const el of metadata[key] || []) {
      const connectors: { target: string; label: string | null }[] = [];

      if (el.connector?.targetReference) {
        connectors.push({ target: el.connector.targetReference, label: null });
      }
      // Fault path
      if (el.faultConnector?.targetReference) {
        connectors.push({ target: el.faultConnector.targetReference, label: "Fault" });
      }

      elements.push({
        name: el.name,
        type,
        label: el.label || el.name,
        description: descFn ? descFn(el) : (el.description || null),
        referencedFields: extractFieldRefs(el),
        referencedObjects: extractObjectRefs(el),
        connector: connectors[0]?.target || null,
        connectors,
      });
    }
  }

  return elements;
}

function parseFlowVariables(
  metadata: any
): { name: string; dataType: string; isInput: boolean; isOutput: boolean }[] {
  return (metadata.variables || []).map((v: any) => ({
    name: v.name,
    dataType: v.dataType || "Unknown",
    isInput: v.isInput || false,
    isOutput: v.isOutput || false,
  }));
}

function extractFieldRefs(element: any): string[] {
  const fields = new Set<string>();

  // Extract from inputAssignments, outputAssignments, filters
  for (const key of ["inputAssignments", "outputAssignments", "filters"]) {
    const items = element[key];
    if (Array.isArray(items)) {
      for (const item of items) {
        if (item.field) fields.add(item.field);
      }
    }
  }

  return Array.from(fields);
}

function extractObjectRefs(element: any): string[] {
  const objects = new Set<string>();
  if (element.object) objects.add(element.object);
  if (element.objectType) objects.add(element.objectType);
  return Array.from(objects);
}
