import { useParams, Link } from "react-router-dom";
import { useUserDetail, useUserRecords } from "../hooks/useUsers";

export function UserDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: user, isLoading, error } = useUserDetail(id);
  const {
    data: recordCounts,
    isLoading: isLoadingRecords,
    load: loadRecords,
  } = useUserRecords(id);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-48 animate-pulse rounded bg-muted" />
        <div className="h-40 animate-pulse rounded-lg bg-muted" />
      </div>
    );
  }

  if (error || !user) {
    return (
      <div className="py-12 text-center">
        <p className="text-sm text-destructive">{error || "User not found"}</p>
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
        <span className="text-sm font-medium text-foreground">{user.name}</span>
      </div>

      {/* User header */}
      <div className="flex items-start gap-4">
        <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary text-lg font-bold text-primary-foreground">
          {user.name.split(" ").map((n) => n[0]).join("").toUpperCase().slice(0, 2)}
        </div>
        <div className="flex-1 space-y-1">
          <h1 className="text-2xl font-bold text-foreground">{user.name}</h1>
          <div className="flex items-center gap-3 text-sm text-muted-foreground">
            {user.title && <span>{user.title}</span>}
            {user.department && <span>{user.department}</span>}
          </div>
          <div className="flex items-center gap-2">
            <Link
              to={`/users/profiles/${user.profileId}`}
              className="rounded bg-purple-500/10 px-2 py-0.5 text-xs text-purple-400 hover:bg-purple-500/20"
            >
              {user.profileName}
            </Link>
            {user.roleName && (
              <span className="rounded bg-blue-500/10 px-2 py-0.5 text-xs text-blue-400">
                {user.roleName}
              </span>
            )}
          </div>
        </div>
      </div>

      {/* Info cards */}
      <div className="grid grid-cols-4 gap-4">
        <InfoCard label="Email" value={user.email} />
        <InfoCard label="Username" value={user.username} mono />
        <InfoCard
          label="Last Login"
          value={user.lastLogin ? new Date(user.lastLogin).toLocaleString() : "Never"}
        />
        <InfoCard label="License" value={user.license || user.userType} />
      </div>

      <div className="grid grid-cols-2 gap-6">
        {/* Permission Sets */}
        <div className="rounded-lg border border-border p-4">
          <h3 className="mb-3 text-sm font-medium text-foreground">
            Permission Sets ({user.permissionSets.length})
          </h3>
          {user.permissionSets.length === 0 ? (
            <p className="text-xs text-muted-foreground">No permission sets assigned</p>
          ) : (
            <div className="space-y-2">
              {user.permissionSets.map((ps) => (
                <div key={ps.id} className="rounded border border-border px-3 py-2">
                  <div className="text-sm font-medium text-foreground">{ps.label}</div>
                  <div className="text-xs text-muted-foreground font-mono">{ps.name}</div>
                  {ps.description && (
                    <div className="mt-1 text-xs text-muted-foreground">{ps.description}</div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Record Ownership */}
        <div className="rounded-lg border border-border p-4">
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-medium text-foreground">Record Ownership</h3>
            {recordCounts.length === 0 && !isLoadingRecords && (
              <button
                onClick={loadRecords}
                className="rounded bg-primary px-3 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90"
              >
                Load Counts
              </button>
            )}
          </div>

          {isLoadingRecords ? (
            <div className="flex items-center gap-2">
              <div className="h-4 w-4 animate-spin rounded-full border-2 border-primary border-t-transparent" />
              <span className="text-xs text-muted-foreground">Counting records across objects...</span>
            </div>
          ) : recordCounts.length > 0 ? (
            <div className="space-y-1">
              {recordCounts.map((rc) => (
                <div
                  key={rc.object}
                  className="flex items-center justify-between rounded px-3 py-1.5 hover:bg-accent/30"
                >
                  <Link
                    to={`/objects/${rc.object}`}
                    className="text-sm text-primary hover:underline"
                  >
                    {rc.object}
                  </Link>
                  <span className="rounded bg-muted px-2 py-0.5 text-xs font-medium text-foreground">
                    {rc.count.toLocaleString()}
                  </span>
                </div>
              ))}
              <div className="mt-2 border-t border-border pt-2 text-xs text-muted-foreground">
                Total: {recordCounts.reduce((sum, r) => sum + r.count, 0).toLocaleString()} records
              </div>
            </div>
          ) : (
            <p className="text-xs text-muted-foreground">
              Click "Load Counts" to see how many records this user owns by object
            </p>
          )}
        </div>
      </div>
    </div>
  );
}

function InfoCard({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="rounded-lg border border-border bg-card p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className={`mt-1 text-sm text-foreground truncate ${mono ? "font-mono text-xs" : ""}`}>
        {value}
      </div>
    </div>
  );
}
