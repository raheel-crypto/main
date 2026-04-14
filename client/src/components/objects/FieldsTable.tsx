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
  const [expandedField, setExpandedField] = useState<string | null>(null);
  const [showFormulasOnly, setShowFormulasOnly] = useState(false);

  const filtered = fields
    .filter((f) => {
      const matchesSearch =
        f.name.toLowerCase().includes(search.toLowerCase()) ||
        f.label.toLowerCase().includes(search.toLowerCase());
      const matchesFormula = !showFormulasOnly || f.calculatedFormula;
      return matchesSearch && matchesFormula;
    })
    .sort((a, b) => {
      const aVal = String(a[sortKey]);
      const bVal = String(b[sortKey]);
      return sortAsc ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
    });

  const formulaCount = fields.filter((f) => f.calculatedFormula).length;

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
      <div className="flex items-center gap-3">
        <input
          type="text"
          placeholder="Filter fields..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="flex-1 max-w-sm rounded-lg border border-input bg-background px-4 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        />
        {formulaCount > 0 && (
          <button
            onClick={() => setShowFormulasOnly(!showFormulasOnly)}
            className={cn(
              "rounded-lg border px-3 py-2 text-xs font-medium transition-colors",
              showFormulasOnly
                ? "border-orange-500/50 bg-orange-500/10 text-orange-400"
                : "border-input text-muted-foreground hover:text-foreground"
            )}
          >
            Formula Fields ({formulaCount})
          </button>
        )}
      </div>

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
                Info
              </th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((field) => (
              <FieldRow
                key={field.name}
                field={field}
                objectName={objectName}
                isExpanded={expandedField === field.name}
                onToggle={() =>
                  setExpandedField(
                    expandedField === field.name ? null : field.name
                  )
                }
              />
            ))}
          </tbody>
        </table>
      </div>

      <div className="text-xs text-muted-foreground">
        Showing {filtered.length} of {fields.length} fields
        {showFormulasOnly && ` (formula fields only)`}
      </div>
    </div>
  );
}

function FieldRow({
  field,
  objectName,
  isExpanded,
  onToggle,
}: {
  field: SFField;
  objectName: string;
  isExpanded: boolean;
  onToggle: () => void;
}) {
  const hasDetails = field.calculatedFormula || field.inlineHelpText;

  return (
    <>
      <tr
        className={cn(
          "border-b border-border last:border-0 hover:bg-accent/30",
          hasDetails && "cursor-pointer"
        )}
        onClick={hasDetails ? onToggle : undefined}
      >
        <td className="px-4 py-2">
          <div className="flex items-center gap-2">
            {hasDetails && (
              <svg
                className={cn(
                  "h-3 w-3 shrink-0 text-muted-foreground transition-transform",
                  isExpanded && "rotate-90"
                )}
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                strokeWidth={2}
              >
                <polyline points="9,18 15,12 9,6" />
              </svg>
            )}
            {!hasDetails && <span className="w-3" />}
            <span className="text-foreground">{field.label}</span>
          </div>
        </td>
        <td className="px-4 py-2">
          <span className="font-mono text-xs text-muted-foreground">
            {field.name}
          </span>
        </td>
        <td className="px-4 py-2">
          <div className="flex items-center gap-1.5">
            <span
              className={cn(
                "rounded px-2 py-0.5 text-xs",
                getTypeColor(field.type)
              )}
            >
              {field.type}
            </span>
            {field.calculatedFormula && (
              <span className="rounded bg-orange-500/10 px-1.5 py-0.5 text-xs text-orange-400">
                formula
              </span>
            )}
          </div>
        </td>
        <td className="px-4 py-2">
          <div className="flex items-center gap-1.5">
            {field.required && (
              <span className="text-xs text-destructive">Required</span>
            )}
            {field.unique && (
              <span className="rounded bg-cyan-500/10 px-1.5 py-0.5 text-xs text-cyan-400">
                Unique
              </span>
            )}
            {field.externalId && (
              <span className="rounded bg-purple-500/10 px-1.5 py-0.5 text-xs text-purple-400">
                ExtId
              </span>
            )}
            {field.inlineHelpText && (
              <svg
                className="h-3.5 w-3.5 text-muted-foreground"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                strokeWidth={2}
              >
                <circle cx="12" cy="12" r="10" />
                <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3" />
                <line x1="12" y1="17" x2="12.01" y2="17" />
              </svg>
            )}
          </div>
        </td>
        <td className="px-4 py-2">
          <Link
            to={`/fields?object=${objectName}&field=${field.name}`}
            className="text-xs text-primary hover:underline"
            onClick={(e) => e.stopPropagation()}
          >
            View Usage
          </Link>
        </td>
      </tr>

      {/* Expanded detail row */}
      {isExpanded && hasDetails && (
        <tr className="border-b border-border last:border-0 bg-muted/30">
          <td colSpan={5} className="px-4 py-3">
            <div className="ml-5 space-y-3">
              {/* Description */}
              {field.inlineHelpText && (
                <div>
                  <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    Description
                  </div>
                  <p className="mt-1 text-sm text-foreground">
                    {field.inlineHelpText}
                  </p>
                </div>
              )}

              {/* Formula */}
              {field.calculatedFormula && (
                <div>
                  <div className="flex items-center gap-2">
                    <span className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
                      Formula
                    </span>
                    <span className="rounded bg-orange-500/10 px-1.5 py-0.5 text-xs text-orange-400">
                      returns {field.type}
                    </span>
                  </div>
                  <pre className="mt-1 max-h-48 overflow-auto rounded-lg bg-background border border-border p-3 font-mono text-xs text-foreground leading-relaxed">
                    {field.calculatedFormula}
                  </pre>
                </div>
              )}

              {/* Reference info */}
              {field.referenceTo.length > 0 && (
                <div>
                  <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    References
                  </div>
                  <div className="mt-1 flex gap-1">
                    {field.referenceTo.map((ref) => (
                      <Link
                        key={ref}
                        to={`/objects/${ref}`}
                        className="rounded bg-sf-blue/10 px-2 py-0.5 text-xs text-sf-blue hover:bg-sf-blue/20"
                      >
                        {ref}
                      </Link>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </td>
        </tr>
      )}
    </>
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
