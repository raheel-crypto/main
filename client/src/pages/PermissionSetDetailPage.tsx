import { useParams, Link } from "react-router-dom";
import { usePermissionSetDetail } from "../hooks/useUsers";
import { ProfilePermissionsView } from "../components/users/ProfilePermissionsView";

export function PermissionSetDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: ps, isLoading, error } = usePermissionSetDetail(id);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-48 animate-pulse rounded bg-muted" />
        <div className="h-64 animate-pulse rounded-lg bg-muted" />
      </div>
    );
  }

  if (error || !ps) {
    return (
      <div className="py-12 text-center">
        <p className="text-sm text-destructive">{error || "Permission set not found"}</p>
        <Link to="/users" className="mt-2 text-sm text-primary hover:underline">
          Back to Users
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2">
        <Link to="/users" className="text-sm text-muted-foreground hover:text-foreground">
          Users
        </Link>
        <span className="text-muted-foreground">/</span>
        <span className="text-sm font-medium text-foreground">{ps.label}</span>
      </div>

      {/* Header */}
      <div className="space-y-2">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-bold text-foreground">{ps.label}</h1>
          <span className="rounded bg-cyan-500/10 px-2 py-0.5 text-xs text-cyan-400">
            Permission Set
          </span>
          <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
            {ps.type}
          </span>
        </div>
        <div className="font-mono text-xs text-muted-foreground">{ps.name}</div>
        {ps.description && (
          <p className="text-sm text-muted-foreground">{ps.description}</p>
        )}
      </div>

      {/* Stats */}
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="text-2xl font-bold text-foreground">{ps.assignees.length}</div>
          <div className="text-xs text-muted-foreground">Assigned Users</div>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="text-2xl font-bold text-foreground">{ps.objectPermissions.length}</div>
          <div className="text-xs text-muted-foreground">Object Permissions</div>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="text-2xl font-bold text-foreground">{ps.fieldPermissions.length}</div>
          <div className="text-xs text-muted-foreground">Field Permissions</div>
        </div>
      </div>

      {/* Assigned users */}
      {ps.assignees.length > 0 && (
        <div className="rounded-lg border border-border p-4">
          <h3 className="mb-2 text-sm font-medium text-foreground">
            Assigned Users
          </h3>
          <div className="flex flex-wrap gap-2">
            {ps.assignees.map((u) => (
              <Link
                key={u.id}
                to={`/users/${u.id}`}
                className="flex items-center gap-2 rounded-lg border border-border px-3 py-1.5 text-sm hover:bg-accent/50"
              >
                <div className="flex h-6 w-6 items-center justify-center rounded-full bg-primary text-xs font-medium text-primary-foreground">
                  {u.name.split(" ").map((n) => n[0]).join("").toUpperCase().slice(0, 2)}
                </div>
                <div>
                  <span className="text-foreground">{u.name}</span>
                  <span className="ml-2 text-xs text-muted-foreground">{u.profileName}</span>
                </div>
              </Link>
            ))}
          </div>
        </div>
      )}

      {/* Permissions */}
      <ProfilePermissionsView
        permissions={{
          objectPermissions: ps.objectPermissions,
          fieldPermissions: ps.fieldPermissions,
        }}
      />
    </div>
  );
}
