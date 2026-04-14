import { useState, useMemo } from "react";
import { cn } from "../../lib/utils";
import type { ProfilePermissions } from "../../lib/api";

interface ProfilePermissionsViewProps {
  permissions: ProfilePermissions;
}

export function ProfilePermissionsView({ permissions }: ProfilePermissionsViewProps) {
  const [objectSearch, setObjectSearch] = useState("");
  const [activeTab, setActiveTab] = useState<"objects" | "fields">("objects");
  const [selectedObject, setSelectedObject] = useState<string>("all");

  const filteredObjPerms = permissions.objectPermissions.filter((p) =>
    p.object.toLowerCase().includes(objectSearch.toLowerCase())
  );

  const objectsWithFieldPerms = useMemo(
    () => Array.from(new Set(permissions.fieldPermissions.map((f) => f.object))).sort(),
    [permissions.fieldPermissions]
  );

  const filteredFieldPerms = permissions.fieldPermissions.filter((p) => {
    const matchesSearch = p.field.toLowerCase().includes(objectSearch.toLowerCase()) ||
      p.object.toLowerCase().includes(objectSearch.toLowerCase());
    const matchesObject = selectedObject === "all" || p.object === selectedObject;
    return matchesSearch && matchesObject;
  });

  const tabs = ["objects", "fields"] as const;

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <div className="border-b border-border">
          <div className="flex gap-0">
            {tabs.map((tab) => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className={cn(
                  "border-b-2 px-4 py-2 text-sm font-medium capitalize transition-colors",
                  activeTab === tab
                    ? "border-primary text-foreground"
                    : "border-transparent text-muted-foreground hover:text-foreground"
                )}
              >
                {tab === "objects"
                  ? `Object CRUD (${permissions.objectPermissions.length})`
                  : `Field Security (${permissions.fieldPermissions.length})`}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="flex items-center gap-3">
        <input
          type="text"
          placeholder={activeTab === "objects" ? "Filter objects..." : "Filter fields..."}
          value={objectSearch}
          onChange={(e) => setObjectSearch(e.target.value)}
          className="flex-1 max-w-sm rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        />
        {activeTab === "fields" && (
          <select
            value={selectedObject}
            onChange={(e) => setSelectedObject(e.target.value)}
            className="rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
          >
            <option value="all">All Objects</option>
            {objectsWithFieldPerms.map((o) => (
              <option key={o} value={o}>{o}</option>
            ))}
          </select>
        )}
      </div>

      {activeTab === "objects" ? (
        <div className="rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-4 py-2 text-left font-medium text-muted-foreground">Object</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Create</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Read</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Edit</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Delete</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">View All</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Modify All</th>
              </tr>
            </thead>
            <tbody>
              {filteredObjPerms.map((perm) => (
                <tr
                  key={perm.object}
                  className="border-b border-border last:border-0 hover:bg-accent/30"
                >
                  <td className="px-4 py-2">
                    <span className="text-sm text-foreground">{perm.object}</span>
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.create} />
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.read} />
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.edit} />
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.delete} />
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.viewAll} />
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.modifyAll} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {filteredObjPerms.length === 0 && (
            <div className="py-8 text-center text-sm text-muted-foreground">
              No object permissions found
            </div>
          )}
        </div>
      ) : (
        <div className="rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-4 py-2 text-left font-medium text-muted-foreground">Object</th>
                <th className="px-4 py-2 text-left font-medium text-muted-foreground">Field</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Read</th>
                <th className="px-3 py-2 text-center font-medium text-muted-foreground">Edit</th>
              </tr>
            </thead>
            <tbody>
              {filteredFieldPerms.slice(0, 200).map((perm, i) => (
                <tr
                  key={`${perm.object}-${perm.field}-${i}`}
                  className="border-b border-border last:border-0 hover:bg-accent/30"
                >
                  <td className="px-4 py-2 text-sm text-foreground">{perm.object}</td>
                  <td className="px-4 py-2">
                    <span className="font-mono text-xs text-muted-foreground">
                      {perm.field.replace(`${perm.object}.`, "")}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.read} />
                  </td>
                  <td className="px-3 py-2 text-center">
                    <PermBadge enabled={perm.edit} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {filteredFieldPerms.length > 200 && (
            <div className="px-4 py-2 text-xs text-muted-foreground">
              Showing 200 of {filteredFieldPerms.length} field permissions
            </div>
          )}
          {filteredFieldPerms.length === 0 && (
            <div className="py-8 text-center text-sm text-muted-foreground">
              No field permissions found
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function PermBadge({ enabled }: { enabled: boolean }) {
  return enabled ? (
    <span className="inline-flex h-5 w-5 items-center justify-center rounded-full bg-green-500/15">
      <svg className="h-3 w-3 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
        <polyline points="20,6 9,17 4,12" />
      </svg>
    </span>
  ) : (
    <span className="inline-flex h-5 w-5 items-center justify-center rounded-full bg-muted">
      <svg className="h-3 w-3 text-muted-foreground/30" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
        <line x1="18" y1="6" x2="6" y2="18" />
        <line x1="6" y1="6" x2="18" y2="18" />
      </svg>
    </span>
  );
}
