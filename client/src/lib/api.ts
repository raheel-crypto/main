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
};

// Types
export interface AuthStatus {
  authenticated: boolean;
  user?: { name: string; email: string; orgId: string; instanceUrl: string };
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

export interface FlowElement {
  name: string;
  type: string;
  label: string;
  description: string | null;
  referencedFields: string[];
  referencedObjects: string[];
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
