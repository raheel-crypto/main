import { Link } from "react-router-dom";
import type { SFField, SFRelationship } from "../../lib/api";

interface RelationshipMapProps {
  relationships: SFRelationship[];
  fields: SFField[];
}

export function RelationshipMap({ relationships, fields }: RelationshipMapProps) {
  const lookupFields = fields.filter(
    (f) => f.type === "reference" && f.referenceTo.length > 0
  );

  return (
    <div className="space-y-6">
      {/* Parent relationships (lookup/master-detail fields) */}
      <div>
        <h3 className="mb-3 text-sm font-medium text-foreground">
          Parent Relationships ({lookupFields.length})
        </h3>
        {lookupFields.length === 0 ? (
          <p className="text-sm text-muted-foreground">No lookup fields</p>
        ) : (
          <div className="space-y-1">
            {lookupFields.map((f) => (
              <div
                key={f.name}
                className="flex items-center justify-between rounded-lg border border-border px-4 py-3"
              >
                <div>
                  <div className="text-sm text-foreground">
                    {f.label}{" "}
                    <span className="font-mono text-xs text-muted-foreground">
                      ({f.name})
                    </span>
                  </div>
                  <div className="text-xs text-muted-foreground">
                    {f.relationshipName
                      ? `Relationship: ${f.relationshipName}`
                      : ""}
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <svg
                    className="h-4 w-4 text-muted-foreground"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    strokeWidth={2}
                  >
                    <path d="M5 12h14M12 5l7 7-7 7" />
                  </svg>
                  {f.referenceTo.map((ref) => (
                    <Link
                      key={ref}
                      to={`/objects/${ref}`}
                      className="rounded bg-sf-blue/10 px-2 py-1 text-xs font-medium text-sf-blue hover:bg-sf-blue/20"
                    >
                      {ref}
                    </Link>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Child relationships */}
      <div>
        <h3 className="mb-3 text-sm font-medium text-foreground">
          Child Relationships ({relationships.length})
        </h3>
        {relationships.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No child relationships
          </p>
        ) : (
          <div className="space-y-1">
            {relationships
              .filter((r) => r.relationshipName)
              .map((r, i) => (
                <div
                  key={`${r.childSObject}-${r.field}-${i}`}
                  className="flex items-center justify-between rounded-lg border border-border px-4 py-3"
                >
                  <div className="flex items-center gap-2">
                    <Link
                      to={`/objects/${r.childSObject}`}
                      className="text-sm font-medium text-primary hover:underline"
                    >
                      {r.childSObject}
                    </Link>
                    <span className="font-mono text-xs text-muted-foreground">
                      via {r.field}
                    </span>
                  </div>
                  <div className="flex items-center gap-2">
                    {r.relationshipName && (
                      <span className="text-xs text-muted-foreground">
                        {r.relationshipName}
                      </span>
                    )}
                    {r.cascadeDelete && (
                      <span className="rounded bg-destructive/10 px-2 py-0.5 text-xs text-destructive">
                        Cascade Delete
                      </span>
                    )}
                  </div>
                </div>
              ))}
          </div>
        )}
      </div>
    </div>
  );
}
