import { useParams, Link } from "react-router-dom";
import { useProfilePermissions, useUsers, useProfiles } from "../hooks/useUsers";
import { ProfilePermissionsView } from "../components/users/ProfilePermissionsView";

export function ProfileDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: permissions, isLoading, error } = useProfilePermissions(id);
  const { data: users } = useUsers();
  const { data: profiles } = useProfiles();

  const profile = profiles.find((p) => p.id === id);
  const profileUsers = users.filter((u) => u.profileId === id);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-48 animate-pulse rounded bg-muted" />
        <div className="h-64 animate-pulse rounded-lg bg-muted" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="py-12 text-center">
        <p className="text-sm text-destructive">{error}</p>
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
        <span className="text-sm font-medium text-foreground">
          {profile?.name || "Profile"}
        </span>
      </div>

      {/* Profile header */}
      <div className="space-y-2">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-bold text-foreground">
            {profile?.name || "Profile"}
          </h1>
          <span className="rounded bg-purple-500/10 px-2 py-0.5 text-xs text-purple-400">
            Profile
          </span>
        </div>
        {profile?.description && (
          <p className="text-sm text-muted-foreground">{profile.description}</p>
        )}
      </div>

      {/* Stats */}
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="text-2xl font-bold text-foreground">{profileUsers.length}</div>
          <div className="text-xs text-muted-foreground">Active Users</div>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="text-2xl font-bold text-foreground">
            {permissions?.objectPermissions.length || 0}
          </div>
          <div className="text-xs text-muted-foreground">Object Permissions</div>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="text-2xl font-bold text-foreground">
            {permissions?.fieldPermissions.length || 0}
          </div>
          <div className="text-xs text-muted-foreground">Field Permissions</div>
        </div>
      </div>

      {/* Users with this profile */}
      {profileUsers.length > 0 && (
        <div className="rounded-lg border border-border p-4">
          <h3 className="mb-2 text-sm font-medium text-foreground">
            Users with this Profile
          </h3>
          <div className="flex flex-wrap gap-2">
            {profileUsers.map((u) => (
              <Link
                key={u.id}
                to={`/users/${u.id}`}
                className="flex items-center gap-2 rounded-lg border border-border px-3 py-1.5 text-sm hover:bg-accent/50"
              >
                <div className="flex h-6 w-6 items-center justify-center rounded-full bg-primary text-xs font-medium text-primary-foreground">
                  {u.name.split(" ").map((n) => n[0]).join("").toUpperCase().slice(0, 2)}
                </div>
                <span className="text-foreground">{u.name}</span>
              </Link>
            ))}
          </div>
        </div>
      )}

      {/* Permissions */}
      {permissions && <ProfilePermissionsView permissions={permissions} />}
    </div>
  );
}
