export function fieldValue(field: any): string | null {
  if (field == null) return null;
  if (typeof field === 'string') return field || null;
  if (typeof field === 'number' || typeof field === 'boolean') return String(field);
  const v = field?.displayValue ?? field?.value;
  if (v == null) return null;
  return String(v) || null;
}
