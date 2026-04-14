import { useState } from "react";
import { Link } from "react-router-dom";
import { cn } from "../../lib/utils";
import type { SFField } from "../../lib/api";

interface FieldsTableProps {
  fields: SFField[];
  objectName: string;
}

type SortKey = "name" | "label" | "type" | "custom";

export function FieldsTable({ fields, objectName }: FieldsTableProps) {
  const [search, setSearch] = useState("");
  const [sortKey, setSortKey] = useState<SortKey>("label");
  const [sortAsc, setSortAsc] = useState(true);

  const filtered = fields
    .filter(
      (f) =>
        f.name.toLowerCase().includes(search.toLowerCase()) ||
        f.label.toLowerCase().includes(search.toLowerCase())
    )
    .sort((a, b) => {
      const aVal = String(a[sortKey]);
      const bVal = String(b[sortKey]);
      return sortAsc ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
    });

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) {
      setSortAsc(!sortAsc);
    } else {
      setSortKey(key);
      setSortAsc(true);
    }
  };

  return (
    <div className="space-y-3">
      <input
        type="text"
        placeholder="Filter fields..."
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        className="w-full max-w-sm rounded-lg border border-input bg-background px-4 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
      />

      <div className="rounded-lg border border-border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border bg-muted/50">
              <SortHeader
                label="Label"
                sortKey="label"
                currentKey={sortKey}
                asc={sortAsc}
                onClick={toggleSort}
              />
              <SortHeader
                label="API Name"
                sortKey="name"
                currentKey={sortKey}
                asc={sortAsc}
                onClick={toggleSort}
              />
              <SortHeader
                label="Type"
                sortKey="type"
                currentKey={sortKey}
                asc={sortAsc}
                onClick={toggleSort}
              />
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">
                Required
              </th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((field) => (
              <tr
                key={field.name}
                className="border-b border-border last:border-0 hover:bg-accent/30"
              >
                <td className="px-4 py-2 text-foreground">{field.label}</td>
                <td className="px-4 py-2">
                  <span className="font-mono text-xs text-muted-foreground">
                    {field.name}
                  </span>
                </td>
                <td className="px-4 py-2">
                  <span
                    className={cn(
                      "rounded px-2 py-0.5 text-xs",
                      getTypeColor(field.type)
                    )}
                  >
                    {field.type}
                  </span>
                </td>
                <td className="px-4 py-2">
                  {field.required && (
                    <span className="text-xs text-destructive">Required</span>
                  )}
                </td>
                <td className="px-4 py-2">
                  <Link
                    to={`/fields?object=${objectName}&field=${field.name}`}
                    className="text-xs text-primary hover:underline"
                  >
                    View Usage
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="text-xs text-muted-foreground">
        Showing {filtered.length} of {fields.length} fields
      </div>
    </div>
  );
}

function SortHeader({
  label,
  sortKey,
  currentKey,
  asc,
  onClick,
}: {
  label: string;
  sortKey: SortKey;
  currentKey: SortKey;
  asc: boolean;
  onClick: (key: SortKey) => void;
}) {
  return (
    <th
      className="cursor-pointer px-4 py-2 text-left font-medium text-muted-foreground hover:text-foreground"
      onClick={() => onClick(sortKey)}
    >
      <span className="flex items-center gap-1">
        {label}
        {currentKey === sortKey && (
          <span className="text-xs">{asc ? "\u2191" : "\u2193"}</span>
        )}
      </span>
    </th>
  );
}

function getTypeColor(type: string): string {
  const colors: Record<string, string> = {
    string: "bg-blue-500/10 text-blue-400",
    textarea: "bg-blue-500/10 text-blue-400",
    boolean: "bg-green-500/10 text-green-400",
    int: "bg-orange-500/10 text-orange-400",
    double: "bg-orange-500/10 text-orange-400",
    currency: "bg-orange-500/10 text-orange-400",
    percent: "bg-orange-500/10 text-orange-400",
    date: "bg-purple-500/10 text-purple-400",
    datetime: "bg-purple-500/10 text-purple-400",
    reference: "bg-yellow-500/10 text-yellow-400",
    picklist: "bg-pink-500/10 text-pink-400",
    multipicklist: "bg-pink-500/10 text-pink-400",
    email: "bg-cyan-500/10 text-cyan-400",
    phone: "bg-cyan-500/10 text-cyan-400",
    url: "bg-cyan-500/10 text-cyan-400",
    id: "bg-gray-500/10 text-gray-400",
  };
  return colors[type] || "bg-muted text-muted-foreground";
}
