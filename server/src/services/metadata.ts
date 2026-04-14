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

  let records: {
    MetadataComponentId: string;
    MetadataComponentName: string;
    MetadataComponentType: string;
  }[] = [];

  // Strategy 1: Query by RefMetadataComponentName (most common)
  try {
    console.log(`[field-usage] Strategy 1: RefMetadataComponentName = '${fullFieldName}'`);
    const query = `
      SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType
      FROM MetadataComponentDependency
      WHERE RefMetadataComponentName = '${fullFieldName}'
    `;
    const result = await conn.tooling.query<{
      MetadataComponentId: string;
      MetadataComponentName: string;
      MetadataComponentType: string;
    }>(query);
    records = result.records || [];
    console.log(`[field-usage] Strategy 1 returned ${records.length} records`);
  } catch (err: any) {
    console.log(`[field-usage] Strategy 1 failed: ${err.message}`);
  }

  // Strategy 2: If Strategy 1 returned nothing, try just the field name
  if (records.length === 0) {
    try {
      console.log(`[field-usage] Strategy 2: RefMetadataComponentName = '${fieldName}'`);
      const query = `
        SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType
        FROM MetadataComponentDependency
        WHERE RefMetadataComponentName = '${fieldName}'
      `;
      const result = await conn.tooling.query<{
        MetadataComponentId: string;
        MetadataComponentName: string;
        MetadataComponentType: string;
      }>(query);
      records = result.records || [];
      console.log(`[field-usage] Strategy 2 returned ${records.length} records`);
    } catch (err: any) {
      console.log(`[field-usage] Strategy 2 failed: ${err.message}`);
    }
  }

  // Strategy 3: Look up CustomField Id and query by RefMetadataComponentId
  if (records.length === 0) {
    try {
      console.log(`[field-usage] Strategy 3: Looking up CustomField Id...`);
      const fieldQuery = `
        SELECT Id FROM CustomField
        WHERE DeveloperName = '${fieldName.replace(/__c$/, '')}'
          AND TableEnumOrId = '${objectName}'
        LIMIT 1
      `;
      const fieldResult = await conn.tooling.query<{ Id: string }>(fieldQuery);
      const fieldId = fieldResult.records?.[0]?.Id;

      if (fieldId) {
        console.log(`[field-usage] Found CustomField Id: ${fieldId}`);
        const depQuery = `
          SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType
          FROM MetadataComponentDependency
          WHERE RefMetadataComponentId = '${fieldId}'
        `;
        const depResult = await conn.tooling.query<{
          MetadataComponentId: string;
          MetadataComponentName: string;
          MetadataComponentType: string;
        }>(depQuery);
        records = depResult.records || [];
        console.log(`[field-usage] Strategy 3 returned ${records.length} records`);
      } else {
        console.log(`[field-usage] Strategy 3: CustomField not found (may be standard field)`);
      }
    } catch (err: any) {
      console.log(`[field-usage] Strategy 3 failed: ${err.message}`);
    }
  }

  // Strategy 4: For standard fields, try FieldDefinition DurableId
  if (records.length === 0) {
    try {
      console.log(`[field-usage] Strategy 4: FieldDefinition DurableId lookup...`);
      const fieldQuery = `
        SELECT DurableId
        FROM FieldDefinition
        WHERE EntityDefinition.QualifiedApiName = '${objectName}'
          AND QualifiedApiName = '${fieldName}'
        LIMIT 1
      `;
      const fieldResult = await conn.tooling.query<{ DurableId: string }>(fieldQuery);
      const durableId = fieldResult.records?.[0]?.DurableId;

      if (durableId) {
        console.log(`[field-usage] Found DurableId: ${durableId}`);
        const depQuery = `
          SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType
          FROM MetadataComponentDependency
          WHERE RefMetadataComponentId = '${durableId}'
        `;
        const depResult = await conn.tooling.query<{
          MetadataComponentId: string;
          MetadataComponentName: string;
          MetadataComponentType: string;
        }>(depQuery);
        records = depResult.records || [];
        console.log(`[field-usage] Strategy 4 returned ${records.length} records`);
      }
    } catch (err: any) {
      console.log(`[field-usage] Strategy 4 failed: ${err.message}`);
    }
  }

  // Strategy 5: Manual scan as last resort
  if (records.length === 0) {
    console.log(`[field-usage] Strategy 5: Manual scan fallback...`);
    records = await scanFieldUsageManually(conn, objectName, fieldName);
    console.log(`[field-usage] Strategy 5 returned ${records.length} records`);
  }

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
  // Query active flows
  const flowQuery = `
    SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType, Status
    FROM Flow
    WHERE Status = 'Active'
    ORDER BY MasterLabel
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
        Definition: { DeveloperName: string } | null;
        MasterLabel: string;
        ProcessType: string;
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
    flows: (flowResult.records || []).map((f: any) => ({
      id: f.Id,
      name: f.Definition?.DeveloperName || f.MasterLabel,
      type: f.ProcessType || "Unknown",
      status: f.Status || "Active",
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

// Manual fallback: scan for field usage when MetadataComponentDependency is unavailable
async function scanFieldUsageManually(
  conn: Connection,
  objectName: string,
  fieldName: string
): Promise<
  { MetadataComponentId: string; MetadataComponentName: string; MetadataComponentType: string }[]
> {
  const results: {
    MetadataComponentId: string;
    MetadataComponentName: string;
    MetadataComponentType: string;
  }[] = [];

  // Scan validation rules on this object
  try {
    const vrQuery = `
      SELECT Id, ValidationName, Metadata
      FROM ValidationRule
      WHERE EntityDefinition.QualifiedApiName = '${objectName}'
    `;
    const vrResult = await conn.tooling.query<{
      Id: string;
      ValidationName: string;
      Metadata: any;
    }>(vrQuery);
    for (const vr of vrResult.records || []) {
      // Check if the field is referenced in the formula
      const meta = JSON.stringify(vr.Metadata || {});
      if (meta.includes(fieldName)) {
        results.push({
          MetadataComponentId: vr.Id,
          MetadataComponentName: vr.ValidationName,
          MetadataComponentType: "ValidationRule",
        });
      }
    }
  } catch (e: any) {
    console.log(`[field-usage] Manual scan VR failed: ${e.message}`);
  }

  // Scan Apex classes that reference this field
  try {
    const apexQuery = `
      SELECT Id, Name, Body
      FROM ApexClass
      WHERE NamespacePrefix = null
    `;
    const apexResult = await conn.tooling.query<{
      Id: string;
      Name: string;
      Body: string;
    }>(apexQuery);
    for (const cls of apexResult.records || []) {
      if (cls.Body && cls.Body.includes(fieldName)) {
        results.push({
          MetadataComponentId: cls.Id,
          MetadataComponentName: cls.Name,
          MetadataComponentType: "ApexClass",
        });
      }
    }
  } catch (e: any) {
    console.log(`[field-usage] Manual scan Apex failed: ${e.message}`);
  }

  // Scan triggers on this object
  try {
    const triggerQuery = `
      SELECT Id, Name, Body
      FROM ApexTrigger
      WHERE TableEnumOrId = '${objectName}'
    `;
    const triggerResult = await conn.tooling.query<{
      Id: string;
      Name: string;
      Body: string;
    }>(triggerQuery);
    for (const t of triggerResult.records || []) {
      if (t.Body && t.Body.includes(fieldName)) {
        results.push({
          MetadataComponentId: t.Id,
          MetadataComponentName: t.Name,
          MetadataComponentType: "ApexTrigger",
        });
      }
    }
  } catch (e: any) {
    console.log(`[field-usage] Manual scan Triggers failed: ${e.message}`);
  }

  // Scan flows for field references
  try {
    const flowQuery = `
      SELECT Id, Definition.DeveloperName, MasterLabel, Metadata
      FROM Flow
      WHERE Status = 'Active'
    `;
    const flowResult = await conn.tooling.query<{
      Id: string;
      Definition: { DeveloperName: string } | null;
      MasterLabel: string;
      Metadata: any;
    }>(flowQuery);
    for (const f of flowResult.records || []) {
      const meta = JSON.stringify(f.Metadata || {});
      if (meta.includes(fieldName)) {
        results.push({
          MetadataComponentId: f.Id,
          MetadataComponentName: f.Definition?.DeveloperName || f.MasterLabel,
          MetadataComponentType: "Flow",
        });
      }
    }
  } catch (e: any) {
    console.log(`[field-usage] Manual scan Flows failed: ${e.message}`);
  }

  return results;
}
