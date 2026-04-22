const API_BASE = "";

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    ...options,
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({ message: res.statusText }));
    throw new Error(error.message || `Request failed: ${res.status}`);
  }

  return res.json();
}

export const api = {
  // Auth
  getAuthStatus: () => request<AuthStatus>("/auth/status"),
  logout: () => request("/auth/logout", { method: "POST" }),

  // Objects
  getObjects: (filter?: string) =>
    request<SFObject[]>(`/api/objects${filter ? `?filter=${filter}` : ""}`),
  getObject: (name: string) => request<SFObjectDetail>(`/api/objects/${name}`),
  getObjectAutomations: (name: string) =>
    request<ObjectAutomations>(`/api/objects/${name}/automations`),

  // Fields
  getFieldUsage: (object: string, field: string) =>
    request<FieldUsageTree>(`/api/fields/${object}/${field}/usage`),

  // Flows
  getFlows: () => request<FlowSummary[]>("/api/flows"),
  getFlow: (id: string) => request<FlowDetail>(`/api/flows/${id}`),
  explainFlow: (id: string) =>
    request<AIExplanation>(`/api/flows/${id}/explain`, { method: "POST" }),
  assessFlow: (id: string) =>
    request<AIExplanation>(`/api/flows/${id}/assess`, { method: "POST" }),

  // Apex
  getApexClasses: () => request<ApexSummary[]>("/api/apex"),
  getApexClass: (id: string) => request<ApexDetail>(`/api/apex/${id}`),
  explainApex: (id: string) =>
    request<AIExplanation>(`/api/apex/${id}/explain`, { method: "POST" }),

  // Users & Profiles
  getUsers: () => request<UserSummary[]>("/api/users"),
  getUser: (id: string) => request<UserDetail>(`/api/users/${id}`),
  getUserRecords: (id: string) =>
    request<RecordCount[]>(`/api/users/${id}/records`),
  getProfiles: () => request<ProfileSummary[]>("/api/users/profiles"),
  getProfilePermissions: (id: string) =>
    request<ProfilePermissions>(`/api/users/profiles/${id}/permissions`),
  getPermissionSets: () =>
    request<PermissionSetSummary[]>("/api/users/permission-sets"),
  getPermissionSetDetail: (id: string) =>
    request<PermissionSetDetail>(`/api/users/permission-sets/${id}`),

  // Cleanup & Architect
  runCleanupScan: () => request<CleanupFinding[]>("/api/cleanup/scan"),
  architectChat: (messages: { role: string; content: string }[]) =>
    request<ArchitectMessage>("/api/cleanup/architect", {
      method: "POST",
      body: JSON.stringify({ messages }),
    }),

  // Bulk Match
  uploadBulkCSV: (file: File) => {
    const form = new FormData();
    form.append("file", file);
    return fetch("/api/bulk/upload", {
      method: "POST",
      credentials: "include",
      body: form,
    }).then(async (res) => {
      if (!res.ok) {
        const err = await res.json().catch(() => ({ message: res.statusText }));
        throw new Error(err.message);
      }
      return res.json() as Promise<BulkUploadResult>;
    });
  },
  getBulkObjects: () => request<{ name: string; label: string; custom: boolean }[]>("/api/bulk/objects"),
  getBulkFields: (object: string) =>
    request<{ matchFields: BulkField[]; writableFields: BulkField[] }>(`/api/bulk/fields/${object}`),
  startBulkMatch: (jobId: string, objectName: string, csvColumn: string, sfField: string) =>
    request<{ status: string }>("/api/bulk/match", {
      method: "POST",
      body: JSON.stringify({ jobId, objectName, csvColumn, sfField }),
    }),
  getBulkJobStatus: (jobId: string) => request<BulkJobStatus>(`/api/bulk/jobs/${jobId}/status`),
  getBulkJobResults: (jobId: string) => request<BulkJobResults>(`/api/bulk/jobs/${jobId}/results`),
  startBulkUpdate: (jobId: string, objectName: string, fieldMapping: { csvColumn: string; sfField: string }[]) =>
    request<{ status: string }>("/api/bulk/update", {
      method: "POST",
      body: JSON.stringify({ jobId, objectName, fieldMapping }),
    }),

  // MCP auth status
  getMcpAuthStatus: () => request<{ configured: boolean; connected: boolean }>("/auth/mcp-status"),

  // Salesforce Hosted MCP
  getSFMcpTools: () => request<SFMcpToolsResponse>("/api/sf-mcp/tools"),
  callSFMcpTool: (toolName: string, toolArgs: Record<string, any>) =>
    request<{ result: string }>("/api/sf-mcp/call", {
      method: "POST",
      body: JSON.stringify({ toolName, toolArgs }),
    }),
  setSFMcpToken: (accessToken: string) =>
    request<{ ok: boolean }>("/api/sf-mcp/token", {
      method: "POST",
      body: JSON.stringify({ accessToken }),
    }),
  clearSFMcpToken: () =>
    request<{ ok: boolean }>("/api/sf-mcp/token", { method: "DELETE" }),
};

// Types
export interface AuthStatus {
  authenticated: boolean;
  user?: {
    name: string;
    email: string;
    orgId: string;
    instanceUrl: string;
    environment: "production" | "sandbox";
  };
}

export interface SFObject {
  name: string;
  label: string;
  custom: boolean;
  keyPrefix: string | null;
  queryable: boolean;
}

export interface SFField {
  name: string;
  label: string;
  type: string;
  custom: boolean;
  required: boolean;
  unique: boolean;
  externalId: boolean;
  length: number | null;
  referenceTo: string[];
  relationshipName: string | null;
  inlineHelpText: string | null;
  calculatedFormula: string | null;
  defaultValue: unknown;
}

export interface SFRelationship {
  childSObject: string;
  field: string;
  relationshipName: string | null;
  cascadeDelete: boolean;
}

export interface SFObjectDetail {
  name: string;
  label: string;
  custom: boolean;
  fields: SFField[];
  relationships: SFRelationship[];
  recordTypes: { id: string; name: string; active: boolean }[];
  childRelationships: SFRelationship[];
}

export interface ObjectAutomations {
  flows: { id: string; name: string; type: string; status: string }[];
  validationRules: { id: string; name: string; active: boolean; formula: string }[];
  triggers: { id: string; name: string; status: string }[];
}

export interface FieldUsageNode {
  type: string;
  name: string;
  id: string;
}

export interface FieldUsageTree {
  field: string;
  object: string;
  categories: {
    category: string;
    items: FieldUsageNode[];
  }[];
  totalReferences: number;
}

export interface FlowSummary {
  id: string;
  name: string;
  label: string;
  type: string;
  status: string;
  triggerObject: string | null;
  triggerType: string | null;
  lastModified: string;
}

export interface FlowConnector {
  target: string;
  label: string | null;
}

export interface FlowElement {
  name: string;
  type: string;
  label: string;
  description: string | null;
  referencedFields: string[];
  referencedObjects: string[];
  connectors: FlowConnector[];
  connector: string | null;
}

export interface FlowDetail {
  id: string;
  name: string;
  label: string;
  type: string;
  status: string;
  triggerObject: string | null;
  triggerType: string | null;
  description: string | null;
  elements: FlowElement[];
  variables: { name: string; dataType: string; isInput: boolean; isOutput: boolean }[];
  referencedObjects: string[];
  referencedFields: string[];
}

export interface ApexSummary {
  id: string;
  name: string;
  status: string;
  apiVersion: number;
  lengthWithoutComments: number;
  lastModified: string;
}

export interface ApexDetail {
  id: string;
  name: string;
  body: string;
  status: string;
  apiVersion: number;
  lastModified: string;
  referencedObjects: string[];
  referencedFields: string[];
  soqlQueries: string[];
  dmlOperations: string[];
  annotations: string[];
  isTest: boolean;
  isTrigger: boolean;
}

export interface AIExplanation {
  summary: string;
  details: string;
  objectsAndFields: { object: string; fields: string[] }[];
  suggestions: string[];
}

export interface UserSummary {
  id: string;
  name: string;
  email: string;
  username: string;
  profileId: string;
  profileName: string;
  roleName: string | null;
  lastLogin: string | null;
  userType: string;
  license: string | null;
  title: string | null;
  department: string | null;
  company: string | null;
  createdDate: string;
  managerName: string | null;
}

export interface UserDetail extends UserSummary {
  permissionSets: {
    id: string;
    name: string;
    label: string;
    description: string | null;
  }[];
}

export interface RecordCount {
  object: string;
  count: number;
}

export interface ProfileSummary {
  id: string;
  name: string;
  userType: string;
  description: string | null;
  activeUserCount: number;
}

export interface ObjectPermission {
  object: string;
  create: boolean;
  read: boolean;
  edit: boolean;
  delete: boolean;
  viewAll: boolean;
  modifyAll: boolean;
}

export interface FieldPermission {
  object: string;
  field: string;
  read: boolean;
  edit: boolean;
}

export interface ProfilePermissions {
  objectPermissions: ObjectPermission[];
  fieldPermissions: FieldPermission[];
}

export interface PermissionSetSummary {
  id: string;
  name: string;
  label: string;
  description: string | null;
  type: string;
  isGroup: boolean;
  assigneeCount: number;
}

export interface PermissionSetDetail {
  id: string;
  name: string;
  label: string;
  description: string | null;
  type: string;
  assignees: { id: string; name: string; email: string; profileName: string }[];
  objectPermissions: ObjectPermission[];
  fieldPermissions: FieldPermission[];
}

export interface CleanupFinding {
  category: string;
  severity: "high" | "medium" | "low";
  item: string;
  object: string | null;
  detail: string;
  recommendation: string;
}

export interface ArchitectMessage {
  role: "assistant";
  content: string;
  toolCalls?: { name: string; input: any; result: string }[];
}

export interface BulkUploadResult {
  jobId: string;
  headers: string[];
  preview: Record<string, string>[];
  rowCount: number;
}

export interface BulkField {
  name: string;
  label: string;
  type: string;
}

export interface BulkJobStatus {
  status: string;
  progress: number;
  total: number;
  matched: number;
  unmatched: number;
  duplicates: number;
  updateSuccessCount: number;
  updateFailedCount: number;
  error: string | null;
}

export interface BulkJobResults {
  status: string;
  matched: { csvRow: Record<string, string>; sfId: string; sfName: string }[];
  unmatched: Record<string, string>[];
  duplicates: { csvRow: Record<string, string>; sfIds: string[]; sfNames: string[] }[];
  updateFailures: { id: string; error: string }[];
}

export interface SFMcpTool {
  name: string;
  description: string;
  inputSchema: Record<string, any>;
}

export interface SFMcpToolsResponse {
  tools: SFMcpTool[];
  connected: boolean;
  usingCustomToken?: boolean;
  error?: string;
}
