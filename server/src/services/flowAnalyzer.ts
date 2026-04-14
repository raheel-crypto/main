import { Connection } from "jsforce";
import type { FlowDetailParsed, FlowElementParsed } from "../types/index.js";

export async function listFlows(conn: Connection) {
  const query = `
    SELECT Id, ApiName, Label, ProcessType, TriggerType,
           TriggerObjectOrEvent.QualifiedApiName, Description,
           ActiveVersionId, LatestVersionId, LastModifiedDate
    FROM FlowDefinitionView
    ORDER BY Label
  `;

  const result = await conn.tooling.query<{
    Id: string;
    ApiName: string;
    Label: string;
    ProcessType: string;
    TriggerType: string | null;
    TriggerObjectOrEvent: { QualifiedApiName: string } | null;
    Description: string | null;
    ActiveVersionId: string | null;
    LatestVersionId: string;
    LastModifiedDate: string;
  }>(query);

  return (result.records || []).map((f) => ({
    id: f.ActiveVersionId || f.LatestVersionId,
    name: f.ApiName,
    label: f.Label,
    type: f.ProcessType,
    status: f.ActiveVersionId ? "Active" : "Draft",
    triggerObject: f.TriggerObjectOrEvent?.QualifiedApiName || null,
    triggerType: f.TriggerType || null,
    lastModified: f.LastModifiedDate,
  }));
}

export async function getFlowDetail(
  conn: Connection,
  flowId: string
): Promise<FlowDetailParsed> {
  const query = `
    SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType,
           Status, Metadata
    FROM Flow
    WHERE Id = '${flowId}'
  `;

  const result = await conn.tooling.query<{
    Id: string;
    Definition: { DeveloperName: string };
    MasterLabel: string;
    ProcessType: string;
    Status: string;
    Metadata: any;
  }>(query);

  const flow = result.records[0];
  if (!flow) {
    throw new Error(`Flow not found: ${flowId}`);
  }

  const metadata = flow.Metadata || {};
  const elements = parseFlowElements(metadata);
  const variables = parseFlowVariables(metadata);

  // Extract all referenced objects and fields
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

  // Start element
  if (metadata.start) {
    elements.push({
      name: "start",
      type: "Start",
      label: "Start",
      description: metadata.start.triggerType
        ? `Triggered by: ${metadata.start.triggerType} on ${metadata.start.object || "N/A"}`
        : "Flow start",
      referencedFields: extractFieldRefs(metadata.start),
      referencedObjects: metadata.start.object
        ? [metadata.start.object]
        : [],
      connector: metadata.start.connector?.targetReference || null,
    });
  }

  // Decisions
  for (const d of metadata.decisions || []) {
    elements.push({
      name: d.name,
      type: "Decision",
      label: d.label || d.name,
      description: d.description || null,
      referencedFields: extractFieldRefs(d),
      referencedObjects: extractObjectRefs(d),
      connector: d.defaultConnector?.targetReference || null,
    });
  }

  // Record Lookups
  for (const r of metadata.recordLookups || []) {
    elements.push({
      name: r.name,
      type: "RecordLookup",
      label: r.label || r.name,
      description: `Get records from ${r.object || "Unknown"}`,
      referencedFields: extractFieldRefs(r),
      referencedObjects: r.object ? [r.object] : [],
      connector: r.connector?.targetReference || null,
    });
  }

  // Record Creates
  for (const r of metadata.recordCreates || []) {
    elements.push({
      name: r.name,
      type: "RecordCreate",
      label: r.label || r.name,
      description: `Create ${r.object || "Unknown"} record`,
      referencedFields: extractFieldRefs(r),
      referencedObjects: r.object ? [r.object] : [],
      connector: r.connector?.targetReference || null,
    });
  }

  // Record Updates
  for (const r of metadata.recordUpdates || []) {
    elements.push({
      name: r.name,
      type: "RecordUpdate",
      label: r.label || r.name,
      description: `Update ${r.object || "Unknown"} record`,
      referencedFields: extractFieldRefs(r),
      referencedObjects: r.object ? [r.object] : [],
      connector: r.connector?.targetReference || null,
    });
  }

  // Record Deletes
  for (const r of metadata.recordDeletes || []) {
    elements.push({
      name: r.name,
      type: "RecordDelete",
      label: r.label || r.name,
      description: `Delete ${r.object || "Unknown"} record`,
      referencedFields: extractFieldRefs(r),
      referencedObjects: r.object ? [r.object] : [],
      connector: r.connector?.targetReference || null,
    });
  }

  // Assignments
  for (const a of metadata.assignments || []) {
    elements.push({
      name: a.name,
      type: "Assignment",
      label: a.label || a.name,
      description: a.description || "Assign variable values",
      referencedFields: extractFieldRefs(a),
      referencedObjects: extractObjectRefs(a),
      connector: a.connector?.targetReference || null,
    });
  }

  // Loops
  for (const l of metadata.loops || []) {
    elements.push({
      name: l.name,
      type: "Loop",
      label: l.label || l.name,
      description: l.description || "Loop through collection",
      referencedFields: extractFieldRefs(l),
      referencedObjects: extractObjectRefs(l),
      connector: l.nextValueConnector?.targetReference || null,
    });
  }

  // Screens
  for (const s of metadata.screens || []) {
    elements.push({
      name: s.name,
      type: "Screen",
      label: s.label || s.name,
      description: s.description || "Screen interaction",
      referencedFields: extractFieldRefs(s),
      referencedObjects: extractObjectRefs(s),
      connector: s.connector?.targetReference || null,
    });
  }

  // Action Calls (invocable actions, apex actions, etc.)
  for (const a of metadata.actionCalls || []) {
    elements.push({
      name: a.name,
      type: "ActionCall",
      label: a.label || a.name,
      description: `Action: ${a.actionName || a.actionType || "Unknown"}`,
      referencedFields: extractFieldRefs(a),
      referencedObjects: extractObjectRefs(a),
      connector: a.connector?.targetReference || null,
    });
  }

  // Subflows
  for (const s of metadata.subflows || []) {
    elements.push({
      name: s.name,
      type: "Subflow",
      label: s.label || s.name,
      description: `Subflow: ${s.flowName || "Unknown"}`,
      referencedFields: extractFieldRefs(s),
      referencedObjects: extractObjectRefs(s),
      connector: s.connector?.targetReference || null,
    });
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
  const json = JSON.stringify(element);

  // Match patterns like "Object.Field" in field references
  const fieldPattern = /\b([A-Z][a-zA-Z0-9_]*\.[A-Z][a-zA-Z0-9_]*__c)\b/g;
  let match;
  while ((match = fieldPattern.exec(json)) !== null) {
    fields.add(match[1]);
  }

  // Extract from inputAssignments, outputAssignments, filters
  for (const key of [
    "inputAssignments",
    "outputAssignments",
    "filters",
    "filterLogic",
  ]) {
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
