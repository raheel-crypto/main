import "express-session";

declare module "express-session" {
  interface SessionData {
    sf?: {
      accessToken: string;
      refreshToken: string;
      instanceUrl: string;
      userId: string;
      orgId: string;
      userName: string;
      userEmail: string;
    };
    mcpToken?: string;
    mcpCodeVerifier?: string;
  }
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

export interface FlowConnector {
  target: string;
  label: string | null;
}

export interface FlowElementParsed {
  name: string;
  type: string;
  label: string;
  description: string | null;
  referencedFields: string[];
  referencedObjects: string[];
  connector: string | null;
  connectors: FlowConnector[];
}

export interface FlowDetailParsed {
  id: string;
  name: string;
  label: string;
  type: string;
  status: string;
  triggerObject: string | null;
  triggerType: string | null;
  description: string | null;
  elements: FlowElementParsed[];
  variables: {
    name: string;
    dataType: string;
    isInput: boolean;
    isOutput: boolean;
  }[];
  referencedObjects: string[];
  referencedFields: string[];
}

export interface ApexDetailParsed {
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
