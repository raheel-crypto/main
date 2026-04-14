import { Connection } from "jsforce";
import type { ApexDetailParsed } from "../types/index.js";

export async function listApexClasses(conn: Connection) {
  const query = `
    SELECT Id, Name, Status, ApiVersion, LengthWithoutComments,
           LastModifiedDate, NamespacePrefix
    FROM ApexClass
    WHERE NamespacePrefix = null
    ORDER BY Name
  `;

  const result = await conn.tooling.query<{
    Id: string;
    Name: string;
    Status: string;
    ApiVersion: number;
    LengthWithoutComments: number;
    LastModifiedDate: string;
    NamespacePrefix: string | null;
  }>(query);

  return (result.records || []).map((c) => ({
    id: c.Id,
    name: c.Name,
    status: c.Status,
    apiVersion: c.ApiVersion,
    lengthWithoutComments: c.LengthWithoutComments,
    lastModified: c.LastModifiedDate,
  }));
}

export async function getApexDetail(
  conn: Connection,
  classId: string
): Promise<ApexDetailParsed> {
  const query = `
    SELECT Id, Name, Body, Status, ApiVersion, LastModifiedDate
    FROM ApexClass
    WHERE Id = '${classId}'
  `;

  const result = await conn.tooling.query<{
    Id: string;
    Name: string;
    Body: string;
    Status: string;
    ApiVersion: number;
    LastModifiedDate: string;
  }>(query);

  const cls = result.records[0];
  if (!cls) {
    throw new Error(`Apex class not found: ${classId}`);
  }

  const body = cls.Body || "";
  const analysis = analyzeApexSource(body);

  return {
    id: cls.Id,
    name: cls.Name,
    body,
    status: cls.Status,
    apiVersion: cls.ApiVersion,
    lastModified: cls.LastModifiedDate,
    ...analysis,
  };
}

function analyzeApexSource(body: string): {
  referencedObjects: string[];
  referencedFields: string[];
  soqlQueries: string[];
  dmlOperations: string[];
  annotations: string[];
  isTest: boolean;
  isTrigger: boolean;
} {
  const soqlQueries: string[] = [];
  const referencedObjects = new Set<string>();
  const referencedFields = new Set<string>();
  const dmlOperations: string[] = [];
  const annotations: string[] = [];

  // Extract SOQL queries
  const soqlPattern = /\[[\s]*SELECT\s+[\s\S]*?FROM\s+(\w+)[\s\S]*?\]/gi;
  let match;
  while ((match = soqlPattern.exec(body)) !== null) {
    soqlQueries.push(match[0].trim());
    referencedObjects.add(match[1]);
  }

  // Extract fields from SOQL SELECT clauses
  const selectPattern =
    /SELECT\s+([\s\S]*?)\s+FROM/gi;
  while ((match = selectPattern.exec(body)) !== null) {
    const fieldList = match[1].split(",").map((f) => f.trim());
    for (const field of fieldList) {
      if (field && !field.includes("(")) {
        referencedFields.add(field);
      }
    }
  }

  // Extract DML operations
  const dmlPatterns = [
    /\b(insert)\s+/gi,
    /\b(update)\s+/gi,
    /\b(delete)\s+/gi,
    /\b(upsert)\s+/gi,
    /\b(merge)\s+/gi,
    /\b(undelete)\s+/gi,
    /Database\.(insert|update|delete|upsert)/gi,
  ];

  for (const pattern of dmlPatterns) {
    while ((match = pattern.exec(body)) !== null) {
      dmlOperations.push(match[0].trim());
    }
  }

  // Extract annotations
  const annotationPattern = /@\w+(\([^)]*\))?/g;
  while ((match = annotationPattern.exec(body)) !== null) {
    annotations.push(match[0]);
  }

  // Check if test class
  const isTest =
    /@isTest/i.test(body) || /@testSetup/i.test(body);

  // Check if trigger (basic heuristic)
  const isTrigger = /\btrigger\s+\w+\s+on\s+\w+/i.test(body);

  return {
    referencedObjects: Array.from(referencedObjects),
    referencedFields: Array.from(referencedFields),
    soqlQueries: [...new Set(soqlQueries)],
    dmlOperations: [...new Set(dmlOperations)],
    annotations: [...new Set(annotations)],
    isTest,
    isTrigger,
  };
}
