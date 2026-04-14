import { Connection } from "jsforce";
import type { FieldUsageTree } from "../types/index.js";

export async function listObjects(
  conn: Connection,
  filter?: string
): Promise<
  {
    name: string;
    label: string;
    custom: boolean;
    keyPrefix: string | null | undefined;
    queryable: boolean;
  }[]
> {
  const result = await conn.describeGlobal();
  let objects = result.sobjects;

  if (filter === "custom") {
    objects = objects.filter((o) => o.custom);
  } else if (filter === "standard") {
    objects = objects.filter((o) => !o.custom);
  }

  return objects.map((o) => ({
    name: o.name,
    label: o.label,
    custom: o.custom,
    keyPrefix: o.keyPrefix,
    queryable: o.queryable,
  }));
}

export async function describeObject(
  conn: Connection,
  objectName: string
) {
  const desc = await conn.describe(objectName);

  return {
    name: desc.name,
    label: desc.label,
    custom: desc.custom,
    fields: desc.fields.map((f) => ({
      name: f.name,
      label: f.label,
      type: f.type,
      custom: f.custom,
      required: !f.nillable && !f.defaultedOnCreate,
      unique: f.unique,
      externalId: f.externalId,
      length: f.length || null,
      referenceTo: f.referenceTo || [],
      relationshipName: f.relationshipName || null,
      inlineHelpText: f.inlineHelpText || null,
      calculatedFormula: f.calculatedFormula || null,
      defaultValue: f.defaultValue,
    })),
    relationships: (desc.childRelationships || []).map((r) => ({
      childSObject: r.childSObject,
      field: r.field,
      relationshipName: r.relationshipName || null,
      cascadeDelete: r.cascadeDelete,
    })),
    recordTypes: (desc.recordTypeInfos || []).map((rt) => ({
      id: rt.recordTypeId,
      name: rt.name,
      active: rt.available,
    })),
    childRelationships: (desc.childRelationships || []).map((r) => ({
      childSObject: r.childSObject,
      field: r.field,
      relationshipName: r.relationshipName || null,
      cascadeDelete: r.cascadeDelete,
    })),
  };
}

export async function getFieldUsage(
  conn: Connection,
  objectName: string,
  fieldName: string
): Promise<FieldUsageTree> {
  const fullFieldName = `${objectName}.${fieldName}`;

  // Query MetadataComponentDependency via Tooling API
  const query = `
    SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType
    FROM MetadataComponentDependency
    WHERE RefMetadataComponentName = '${fullFieldName}'
    ORDER BY MetadataComponentType, MetadataComponentName
  `;

  const result = await conn.tooling.query<{
    MetadataComponentId: string;
    MetadataComponentName: string;
    MetadataComponentType: string;
  }>(query);

  const records = result.records || [];

  // Group by component type
  const grouped = new Map<
    string,
    { type: string; name: string; id: string }[]
  >();

  for (const record of records) {
    const category = record.MetadataComponentType;
    if (!grouped.has(category)) {
      grouped.set(category, []);
    }
    grouped.get(category)!.push({
      type: category,
      name: record.MetadataComponentName,
      id: record.MetadataComponentId,
    });
  }

  // Convert to categories array with friendly names
  const categoryOrder = [
    "Layout",
    "Flow",
    "ApexClass",
    "ApexTrigger",
    "ValidationRule",
    "WorkflowFieldUpdate",
    "CustomField",
    "Report",
  ];

  const categories = Array.from(grouped.entries())
    .sort(([a], [b]) => {
      const ai = categoryOrder.indexOf(a);
      const bi = categoryOrder.indexOf(b);
      return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
    })
    .map(([category, items]) => ({
      category: formatCategoryName(category),
      items,
    }));

  return {
    field: fieldName,
    object: objectName,
    categories,
    totalReferences: records.length,
  };
}

export async function getObjectAutomations(
  conn: Connection,
  objectName: string
) {
  // Query flows related to this object
  const flowQuery = `
    SELECT Id, ApiName, Label, ProcessType, TriggerType, Status
    FROM FlowDefinitionView
    WHERE TriggerObjectOrEvent.QualifiedApiName = '${objectName}'
    ORDER BY Label
  `;

  // Query validation rules
  const vrQuery = `
    SELECT Id, ValidationName, Active, ErrorMessage
    FROM ValidationRule
    WHERE EntityDefinition.QualifiedApiName = '${objectName}'
    ORDER BY ValidationName
  `;

  // Query triggers
  const triggerQuery = `
    SELECT Id, Name, Status
    FROM ApexTrigger
    WHERE TableEnumOrId = '${objectName}'
    ORDER BY Name
  `;

  const [flowResult, vrResult, triggerResult] = await Promise.all([
    conn.tooling
      .query<{
        Id: string;
        ApiName: string;
        Label: string;
        ProcessType: string;
        TriggerType: string;
        Status: string;
      }>(flowQuery)
      .catch(() => ({ records: [] as any[], done: true, totalSize: 0 })),
    conn.tooling
      .query<{
        Id: string;
        ValidationName: string;
        Active: boolean;
        ErrorMessage: string;
      }>(vrQuery)
      .catch(() => ({ records: [] as any[], done: true, totalSize: 0 })),
    conn.tooling
      .query<{
        Id: string;
        Name: string;
        Status: string;
      }>(triggerQuery)
      .catch(() => ({ records: [] as any[], done: true, totalSize: 0 })),
  ]);

  return {
    flows: (flowResult.records || []).map((f) => ({
      id: f.Id,
      name: f.ApiName || f.Label,
      type: f.ProcessType,
      status: f.Status,
    })),
    validationRules: (vrResult.records || []).map((v) => ({
      id: v.Id,
      name: v.ValidationName,
      active: v.Active,
      formula: v.ErrorMessage || "",
    })),
    triggers: (triggerResult.records || []).map((t) => ({
      id: t.Id,
      name: t.Name,
      status: t.Status,
    })),
  };
}

function formatCategoryName(type: string): string {
  const map: Record<string, string> = {
    Layout: "Page Layouts",
    Flow: "Flows",
    ApexClass: "Apex Classes",
    ApexTrigger: "Apex Triggers",
    ValidationRule: "Validation Rules",
    WorkflowFieldUpdate: "Workflow Field Updates",
    CustomField: "Formula Fields",
    Report: "Reports",
    EmailTemplate: "Email Templates",
    CustomTab: "Custom Tabs",
    FlexiPage: "Lightning Pages",
    QuickAction: "Quick Actions",
  };
  return map[type] || type;
}
