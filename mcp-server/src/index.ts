#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import jsforce, { Connection } from "jsforce";

// --- Connection Management ---

let conn: Connection | null = null;

async function getConnection(): Promise<Connection> {
  if (conn) return conn;

  const loginUrl = process.env.SF_LOGIN_URL || "https://login.salesforce.com";
  const username = process.env.SF_USERNAME;
  const password = process.env.SF_PASSWORD;
  const token = process.env.SF_SECURITY_TOKEN || "";
  const accessToken = process.env.SF_ACCESS_TOKEN;
  const instanceUrl = process.env.SF_INSTANCE_URL;

  if (accessToken && instanceUrl) {
    conn = new jsforce.Connection({ accessToken, instanceUrl });
    return conn;
  }

  if (username && password) {
    conn = new jsforce.Connection({ loginUrl });
    await conn.login(username, password + token);
    return conn;
  }

  throw new Error(
    "Set SF_USERNAME + SF_PASSWORD (+ SF_SECURITY_TOKEN), or SF_ACCESS_TOKEN + SF_INSTANCE_URL"
  );
}

// --- MCP Server ---

const server = new McpServer({
  name: "salesforce",
  version: "1.0.0",
});

// =====================================================
// READ TOOLS
// =====================================================

server.tool(
  "sf_query",
  "Execute a SOQL query against Salesforce. Use for reading data and metadata.",
  { soql: z.string().describe("The SOQL query to execute") },
  async ({ soql }) => {
    const c = await getConnection();
    const result = await c.query(soql);
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify(
            { totalSize: result.totalSize, records: result.records },
            null,
            2
          ),
        },
      ],
    };
  }
);

server.tool(
  "sf_tooling_query",
  "Execute a Tooling API SOQL query. Use for metadata like Flows, ApexClasses, ValidationRules, CustomFields.",
  { soql: z.string().describe("The Tooling API SOQL query") },
  async ({ soql }) => {
    const c = await getConnection();
    const result = await c.tooling.query(soql);
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify(
            { totalSize: result.totalSize, records: result.records },
            null,
            2
          ),
        },
      ],
    };
  }
);

server.tool(
  "sf_describe_object",
  "Get full metadata for a Salesforce object including fields, relationships, and record types.",
  { objectName: z.string().describe("API name of the object, e.g. 'Account'") },
  async ({ objectName }) => {
    const c = await getConnection();
    const desc = await c.describe(objectName);
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify(
            {
              name: desc.name,
              label: desc.label,
              custom: desc.custom,
              fieldCount: desc.fields.length,
              fields: desc.fields.map((f) => ({
                name: f.name,
                label: f.label,
                type: f.type,
                custom: f.custom,
                required: !f.nillable && !f.defaultedOnCreate,
                referenceTo: f.referenceTo,
                calculatedFormula: f.calculatedFormula,
              })),
              recordTypes: desc.recordTypeInfos?.map((rt) => ({
                name: rt.name,
                active: rt.available,
              })),
              childRelationships: desc.childRelationships
                ?.filter((r) => r.relationshipName)
                .map((r) => ({
                  childObject: r.childSObject,
                  field: r.field,
                  relationshipName: r.relationshipName,
                })),
            },
            null,
            2
          ),
        },
      ],
    };
  }
);

server.tool(
  "sf_list_objects",
  "List all Salesforce objects in the org. Use filter to narrow to custom or standard only.",
  {
    filter: z
      .enum(["all", "custom", "standard"])
      .optional()
      .describe("Filter by object type"),
  },
  async ({ filter }) => {
    const c = await getConnection();
    const result = await c.describeGlobal();
    let objects = result.sobjects;
    if (filter === "custom") objects = objects.filter((o) => o.custom);
    if (filter === "standard") objects = objects.filter((o) => !o.custom);

    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify(
            objects.map((o) => ({
              name: o.name,
              label: o.label,
              custom: o.custom,
            })),
            null,
            2
          ),
        },
      ],
    };
  }
);

// =====================================================
// FIELD & OBJECT WRITE TOOLS
// =====================================================

server.tool(
  "sf_create_custom_field",
  "Create a new custom field on a Salesforce object. Deploys via Metadata API.",
  {
    objectName: z.string().describe("API name of the object, e.g. 'Account'"),
    fieldName: z.string().describe("API name for the field WITHOUT __c suffix, e.g. 'Region'"),
    label: z.string().describe("User-visible label, e.g. 'Region'"),
    type: z.enum([
      "Text", "TextArea", "LongTextArea", "RichTextArea",
      "Number", "Currency", "Percent",
      "Date", "DateTime",
      "Checkbox",
      "Email", "Phone", "Url",
      "Picklist", "MultiselectPicklist",
      "Lookup", "MasterDetail",
      "Formula",
    ]).describe("Field data type"),
    description: z.string().optional().describe("Field description / help text"),
    required: z.boolean().optional().describe("Whether the field is required"),
    length: z.number().optional().describe("Length for text fields (default 255)"),
    precision: z.number().optional().describe("Precision for number fields"),
    scale: z.number().optional().describe("Decimal places for number fields"),
    picklistValues: z.array(z.string()).optional().describe("Values for picklist fields"),
    referenceTo: z.string().optional().describe("Target object for Lookup/MasterDetail"),
    formula: z.string().optional().describe("Formula expression for Formula fields"),
    formulaReturnType: z.enum(["Text", "Number", "Date", "DateTime", "Currency", "Percent", "Checkbox"]).optional(),
    defaultValue: z.string().optional().describe("Default value"),
  },
  async (params) => {
    const c = await getConnection();
    const fullName = `${params.objectName}.${params.fieldName}__c`;

    const metadata: any = {
      fullName,
      label: params.label,
      type: params.type,
      description: params.description || "",
      required: params.required || false,
    };

    // Type-specific settings
    if (["Text"].includes(params.type)) {
      metadata.length = params.length || 255;
    }
    if (["LongTextArea", "RichTextArea"].includes(params.type)) {
      metadata.length = params.length || 32768;
      metadata.visibleLines = 5;
    }
    if (["Number", "Currency", "Percent"].includes(params.type)) {
      metadata.precision = params.precision || 18;
      metadata.scale = params.scale || 2;
    }
    if (["Picklist", "MultiselectPicklist"].includes(params.type) && params.picklistValues) {
      metadata.valueSet = {
        restricted: false,
        valueSetDefinition: {
          sorted: false,
          value: params.picklistValues.map((v) => ({
            fullName: v,
            default: false,
            label: v,
          })),
        },
      };
    }
    if (["Lookup", "MasterDetail"].includes(params.type)) {
      metadata.referenceTo = params.referenceTo;
      metadata.relationshipLabel = params.label;
      metadata.relationshipName = params.fieldName;
      if (params.type === "MasterDetail") {
        metadata.writeRequiresMasterRead = false;
        metadata.reparentableMasterDetail = false;
      }
    }
    if (params.type === "Formula") {
      metadata.formula = params.formula;
      metadata.formulaTreatBlanksAs = "BlankAsZero";
      if (params.formulaReturnType) {
        metadata.type = params.formulaReturnType === "Text" ? "Text" : params.formulaReturnType;
      }
    }
    if (params.defaultValue !== undefined) {
      metadata.defaultValue = params.defaultValue;
    }

    await c.metadata.create("CustomField", metadata);

    return {
      content: [
        {
          type: "text" as const,
          text: `Custom field '${fullName}' created successfully.\n\nField details:\n- Label: ${params.label}\n- Type: ${params.type}\n- Required: ${params.required || false}`,
        },
      ],
    };
  }
);

server.tool(
  "sf_update_custom_field",
  "Update an existing custom field's properties.",
  {
    objectName: z.string().describe("API name of the object"),
    fieldName: z.string().describe("Full API name of the field including __c"),
    label: z.string().optional().describe("New label"),
    description: z.string().optional().describe("New description"),
    required: z.boolean().optional().describe("Whether field is required"),
    picklistValues: z.array(z.string()).optional().describe("Replace picklist values"),
  },
  async (params) => {
    const c = await getConnection();
    const fullName = `${params.objectName}.${params.fieldName}`;

    const metadata: any = { fullName };
    if (params.label) metadata.label = params.label;
    if (params.description !== undefined) metadata.description = params.description;
    if (params.required !== undefined) metadata.required = params.required;
    if (params.picklistValues) {
      metadata.valueSet = {
        restricted: false,
        valueSetDefinition: {
          sorted: false,
          value: params.picklistValues.map((v) => ({
            fullName: v,
            default: false,
            label: v,
          })),
        },
      };
    }

    await c.metadata.update("CustomField", metadata);

    return {
      content: [
        {
          type: "text" as const,
          text: `Field '${fullName}' updated successfully.`,
        },
      ],
    };
  }
);

server.tool(
  "sf_delete_custom_field",
  "Delete a custom field from an object. WARNING: This is destructive and cannot be undone easily.",
  {
    objectName: z.string().describe("API name of the object"),
    fieldName: z.string().describe("Full API name of the field including __c"),
  },
  async (params) => {
    const c = await getConnection();
    const fullName = `${params.objectName}.${params.fieldName}`;
    await c.metadata.delete("CustomField", fullName);
    return {
      content: [
        { type: "text" as const, text: `Field '${fullName}' deleted.` },
      ],
    };
  }
);

server.tool(
  "sf_create_custom_object",
  "Create a new custom object in Salesforce.",
  {
    objectName: z.string().describe("API name WITHOUT __c suffix, e.g. 'Invoice'"),
    label: z.string().describe("Singular label, e.g. 'Invoice'"),
    pluralLabel: z.string().describe("Plural label, e.g. 'Invoices'"),
    description: z.string().optional(),
    nameFieldType: z.enum(["Text", "AutoNumber"]).optional().describe("Name field type (default Text)"),
    nameFieldLabel: z.string().optional().describe("Label for the Name field (default: object label + ' Name')"),
    autoNumberFormat: z.string().optional().describe("Format for AutoNumber, e.g. 'INV-{0000}'"),
  },
  async (params) => {
    const c = await getConnection();
    const metadata: any = {
      fullName: `${params.objectName}__c`,
      label: params.label,
      pluralLabel: params.pluralLabel,
      description: params.description || "",
      deploymentStatus: "Deployed",
      sharingModel: "ReadWrite",
      nameField: {
        label: params.nameFieldLabel || `${params.label} Name`,
        type: params.nameFieldType || "Text",
      },
    };

    if (params.nameFieldType === "AutoNumber" && params.autoNumberFormat) {
      metadata.nameField.displayFormat = params.autoNumberFormat;
    }

    await c.metadata.create("CustomObject", metadata);

    return {
      content: [
        {
          type: "text" as const,
          text: `Custom object '${params.objectName}__c' created successfully.`,
        },
      ],
    };
  }
);

// =====================================================
// FLOW TOOLS
// =====================================================

server.tool(
  "sf_list_flows",
  "List all flows in the org with their status, type, and trigger info.",
  {},
  async () => {
    const c = await getConnection();
    const result = await c.tooling.query(`
      SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType,
             Status, VersionNumber
      FROM Flow
      ORDER BY MasterLabel
    `);
    return {
      content: [
        { type: "text" as const, text: JSON.stringify(result.records, null, 2) },
      ],
    };
  }
);

server.tool(
  "sf_get_flow",
  "Get the full definition of a Flow including all elements, connectors, and variables.",
  { flowId: z.string().describe("The Flow version Id (starts with 301)") },
  async ({ flowId }) => {
    const c = await getConnection();
    const result = await c.tooling.query(`
      SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType,
             Status, Metadata
      FROM Flow WHERE Id = '${flowId}'
    `);
    return {
      content: [
        { type: "text" as const, text: JSON.stringify(result.records?.[0], null, 2) },
      ],
    };
  }
);

server.tool(
  "sf_activate_flow",
  "Activate or deactivate a flow version.",
  {
    flowId: z.string().describe("The Flow version Id"),
    active: z.boolean().describe("true to activate, false to deactivate"),
  },
  async ({ flowId, active }) => {
    const c = await getConnection();
    const status = active ? "Active" : "Obsolete";
    await c.tooling.update("Flow", { Id: flowId, Status: status } as any);
    return {
      content: [
        {
          type: "text" as const,
          text: `Flow ${flowId} status set to ${status}.`,
        },
      ],
    };
  }
);

// =====================================================
// VALIDATION RULE TOOLS
// =====================================================

server.tool(
  "sf_list_validation_rules",
  "List validation rules for an object.",
  { objectName: z.string().describe("API name of the object") },
  async ({ objectName }) => {
    const c = await getConnection();
    const result = await c.tooling.query(`
      SELECT Id, ValidationName, Active, Description, ErrorMessage, Metadata
      FROM ValidationRule
      WHERE EntityDefinition.QualifiedApiName = '${objectName}'
      ORDER BY ValidationName
    `);
    return {
      content: [
        { type: "text" as const, text: JSON.stringify(result.records, null, 2) },
      ],
    };
  }
);

server.tool(
  "sf_create_validation_rule",
  "Create a new validation rule on an object.",
  {
    objectName: z.string().describe("API name of the object"),
    ruleName: z.string().describe("API name for the rule, e.g. 'Require_Email'"),
    description: z.string().optional(),
    errorConditionFormula: z.string().describe("Formula that evaluates to true when the rule should fire"),
    errorMessage: z.string().describe("Error message shown to the user"),
    active: z.boolean().optional().describe("Whether the rule is active (default true)"),
  },
  async (params) => {
    const c = await getConnection();
    const fullName = `${params.objectName}.${params.ruleName}`;

    await c.metadata.create("ValidationRule", {
      fullName,
      active: params.active !== false,
      description: params.description || "",
      errorConditionFormula: params.errorConditionFormula,
      errorMessage: params.errorMessage,
    } as any);

    return {
      content: [
        {
          type: "text" as const,
          text: `Validation rule '${fullName}' created.\n- Active: ${params.active !== false}\n- Error: ${params.errorMessage}`,
        },
      ],
    };
  }
);

server.tool(
  "sf_toggle_validation_rule",
  "Enable or disable a validation rule.",
  {
    objectName: z.string(),
    ruleName: z.string().describe("API name of the validation rule"),
    active: z.boolean().describe("true to enable, false to disable"),
  },
  async (params) => {
    const c = await getConnection();
    const fullName = `${params.objectName}.${params.ruleName}`;

    await c.metadata.update("ValidationRule", {
      fullName,
      active: params.active,
    } as any);

    return {
      content: [
        {
          type: "text" as const,
          text: `Validation rule '${fullName}' ${params.active ? "enabled" : "disabled"}.`,
        },
      ],
    };
  }
);

// =====================================================
// PERMISSION & USER TOOLS
// =====================================================

server.tool(
  "sf_list_users",
  "List active users with their profiles and licenses.",
  {},
  async () => {
    const c = await getConnection();
    const result = await c.query(`
      SELECT Id, Name, Email, Username, Profile.Name,
             Profile.UserLicense.Name, UserRole.Name,
             LastLoginDate, IsActive
      FROM User WHERE IsActive = true
      ORDER BY Name
    `);
    return {
      content: [
        { type: "text" as const, text: JSON.stringify(result.records, null, 2) },
      ],
    };
  }
);

server.tool(
  "sf_list_permission_sets",
  "List all permission sets in the org.",
  {},
  async () => {
    const c = await getConnection();
    const result = await c.query(`
      SELECT Id, Name, Label, Description, IsOwnedByProfile
      FROM PermissionSet
      WHERE IsOwnedByProfile = false
      ORDER BY Label
    `);
    return {
      content: [
        { type: "text" as const, text: JSON.stringify(result.records, null, 2) },
      ],
    };
  }
);

server.tool(
  "sf_assign_permission_set",
  "Assign a permission set to a user.",
  {
    userId: z.string().describe("The User Id (starts with 005)"),
    permissionSetId: z.string().describe("The Permission Set Id (starts with 0PS)"),
  },
  async ({ userId, permissionSetId }) => {
    const c = await getConnection();
    await c.sobject("PermissionSetAssignment").create({
      AssigneeId: userId,
      PermissionSetId: permissionSetId,
    });
    return {
      content: [
        {
          type: "text" as const,
          text: `Permission set ${permissionSetId} assigned to user ${userId}.`,
        },
      ],
    };
  }
);

server.tool(
  "sf_remove_permission_set",
  "Remove a permission set assignment from a user.",
  {
    userId: z.string().describe("The User Id"),
    permissionSetId: z.string().describe("The Permission Set Id"),
  },
  async ({ userId, permissionSetId }) => {
    const c = await getConnection();
    const result = await c.query(`
      SELECT Id FROM PermissionSetAssignment
      WHERE AssigneeId = '${userId}' AND PermissionSetId = '${permissionSetId}'
    `);
    const assignmentId = (result.records as any)?.[0]?.Id;
    if (!assignmentId) {
      return {
        content: [
          { type: "text" as const, text: "Assignment not found." },
        ],
      };
    }
    await c.sobject("PermissionSetAssignment").delete(assignmentId);
    return {
      content: [
        {
          type: "text" as const,
          text: `Permission set ${permissionSetId} removed from user ${userId}.`,
        },
      ],
    };
  }
);

server.tool(
  "sf_create_record",
  "Create a new record in any Salesforce object.",
  {
    objectName: z.string().describe("API name of the object, e.g. 'Account'"),
    fields: z.record(z.unknown()).describe("Field values as key-value pairs, e.g. {Name: 'Acme', Industry: 'Tech'}"),
  },
  async ({ objectName, fields }) => {
    const c = await getConnection();
    const result = await c.sobject(objectName).create(fields);
    return {
      content: [
        {
          type: "text" as const,
          text: `Record created. Id: ${(result as any).id}`,
        },
      ],
    };
  }
);

server.tool(
  "sf_update_record",
  "Update an existing record in Salesforce.",
  {
    objectName: z.string().describe("API name of the object"),
    recordId: z.string().describe("The record Id to update"),
    fields: z.record(z.unknown()).describe("Field values to update as key-value pairs"),
  },
  async ({ objectName, recordId, fields }) => {
    const c = await getConnection();
    await c.sobject(objectName).update({ Id: recordId, ...fields });
    return {
      content: [
        {
          type: "text" as const,
          text: `Record ${recordId} on ${objectName} updated successfully.`,
        },
      ],
    };
  }
);

server.tool(
  "sf_deploy_metadata",
  "Deploy raw metadata XML to Salesforce via Metadata API. Use for advanced customizations.",
  {
    metadataType: z.string().describe("Metadata type, e.g. 'CustomField', 'Flow', 'ValidationRule'"),
    metadata: z.record(z.unknown()).describe("Metadata object to deploy. Must include fullName."),
    operation: z.enum(["create", "update", "delete"]).describe("Operation to perform"),
  },
  async ({ metadataType, metadata, operation }) => {
    const c = await getConnection();
    let result;
    if (operation === "create") {
      result = await c.metadata.create(metadataType as any, metadata as any);
    } else if (operation === "update") {
      result = await c.metadata.update(metadataType as any, metadata as any);
    } else {
      result = await c.metadata.delete(
        metadataType as any,
        (metadata as any).fullName
      );
    }
    return {
      content: [
        {
          type: "text" as const,
          text: `Metadata ${operation} on ${metadataType} completed.\n${JSON.stringify(result, null, 2)}`,
        },
      ],
    };
  }
);

// --- Start Server ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Salesforce MCP server running on stdio");
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
