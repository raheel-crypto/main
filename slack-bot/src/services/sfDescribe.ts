import type { Connection } from "jsforce";

export interface DescribedField {
  name: string;
  label: string;
  type: string;
  updateable: boolean;
  createable: boolean;
  calculated: boolean;
  autoNumber: boolean;
  nillable: boolean;
  picklistValues: { value: string; label: string; active: boolean }[];
  referenceTo: string[];
  length: number | null;
}

export interface DescribedObject {
  name: string;
  label: string;
  labelPlural: string;
  fields: Map<string, DescribedField>;
  fieldsByLabel: Map<string, DescribedField>;
  keyPrefix: string | null;
}

const cache = new Map<string, Promise<DescribedObject>>();

function normalize(field: any): DescribedField {
  return {
    name: field.name,
    label: field.label ?? field.name,
    type: field.type,
    updateable: !!field.updateable,
    createable: !!field.createable,
    calculated: !!field.calculated,
    autoNumber: !!field.autoNumber,
    nillable: !!field.nillable,
    picklistValues: (field.picklistValues ?? [])
      .filter((p: any) => p.active)
      .map((p: any) => ({
        value: p.value,
        label: p.label ?? p.value,
        active: !!p.active,
      })),
    referenceTo: Array.isArray(field.referenceTo) ? field.referenceTo : [],
    length: typeof field.length === "number" ? field.length : null,
  };
}

export function describeObject(
  conn: Connection,
  sobjectType: string
): Promise<DescribedObject> {
  const key = sobjectType.toLowerCase();
  let cached = cache.get(key);
  if (cached) return cached;
  cached = (async () => {
    const desc: any = await conn.describe(sobjectType);
    const fields = new Map<string, DescribedField>();
    const fieldsByLabel = new Map<string, DescribedField>();
    for (const f of desc.fields ?? []) {
      const nf = normalize(f);
      fields.set(nf.name.toLowerCase(), nf);
      fieldsByLabel.set(nf.label.toLowerCase(), nf);
    }
    return {
      name: desc.name ?? sobjectType,
      label: desc.label ?? sobjectType,
      labelPlural: desc.labelPlural ?? sobjectType,
      fields,
      fieldsByLabel,
      keyPrefix: desc.keyPrefix ?? null,
    };
  })().catch((err) => {
    cache.delete(key);
    throw err;
  });
  cache.set(key, cached);
  return cached;
}

export function findField(
  obj: DescribedObject,
  query: string
): DescribedField | null {
  const q = query.toLowerCase();
  return obj.fields.get(q) ?? obj.fieldsByLabel.get(q) ?? null;
}

export function suggestFields(
  obj: DescribedObject,
  query: string,
  max = 5
): string[] {
  const q = query.toLowerCase();
  const out = new Set<string>();
  for (const [, f] of obj.fields) {
    if (!f.updateable || f.calculated || f.autoNumber) continue;
    if (
      f.name.toLowerCase().includes(q) ||
      f.label.toLowerCase().includes(q)
    ) {
      out.add(f.name);
      if (out.size >= max) break;
    }
  }
  return [...out];
}

const ID_PREFIX_TO_SOBJECT: Record<string, string> = {
  "001": "Account",
  "003": "Contact",
  "005": "User",
  "006": "Opportunity",
  "00Q": "Lead",
  "00T": "Task",
  "00U": "Event",
  "500": "Case",
};

export function sobjectFromIdPrefix(recordId: string): string | null {
  if (typeof recordId !== "string" || recordId.length < 3) return null;
  return ID_PREFIX_TO_SOBJECT[recordId.slice(0, 3)] ?? null;
}
