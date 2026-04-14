import { useState, useMemo } from "react";
import { Link } from "react-router-dom";
import { cn } from "../../lib/utils";
import type { UserSummary } from "../../lib/api";

interface UserListProps {
  users: UserSummary[];
  isLoading: boolean;
}

export function UserList({ users, isLoading }: UserListProps) {
  const [search, setSearch] = useState("");
  const [profileFilter, setProfileFilter] = useState<string>("all");

  const profiles = useMemo(
    () =>
      Array.from(new Set(users.map((u) => u.profileName)))
        .sort()
        .filter(Boolean),
    [users]
  );

  const filtered = users.filter((u) => {
    const matchesSearch =
      u.name.toLowerCase().includes(search.toLowerCase()) ||
      u.email.toLowerCase().includes(search.toLowerCase()) ||
      u.username.toLowerCase().includes(search.toLowerCase());
    const matchesProfile =
      profileFilter === "all" || u.profileName === profileFilter;
    return matchesSearch && matchesProfile;
  });

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 8 }).map((_, i) => (
          <div key={i} className="h-16 animate-pulse rounded-lg bg-muted" />
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <input
          type="text"
          placeholder="Search users..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="flex-1 max-w-md rounded-lg border border-input bg-background px-4 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        />
        <select
          value={profileFilter}
          onChange={(e) => setProfileFilter(e.target.value)}
          className="rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        >
          <option value="all">All Profiles ({users.length})</option>
          {profiles.map((p) => (
            <option key={p} value={p}>
              {p} ({users.filter((u) => u.profileName === p).length})
            </option>
          ))}
        </select>
      </div>

      <div className="text-xs text-muted-foreground">
        {filtered.length} of {users.length} active users
      </div>

      <div className="rounded-lg border border-border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border bg-muted/50">
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">User</th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">Profile</th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">License</th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">Last Login</th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">Role</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((user) => (
              <tr
                key={user.id}
                className="border-b border-border last:border-0 hover:bg-accent/30"
              >
                <td className="px-4 py-3">
                  <Link
                    to={`/users/${user.id}`}
                    className="block"
                  >
                    <div className="flex items-center gap-3">
                      <div className="flex h-8 w-8 items-center justify-center rounded-full bg-primary text-xs font-medium text-primary-foreground">
                        {user.name.split(" ").map((n) => n[0]).join("").toUpperCase().slice(0, 2)}
                      </div>
                      <div>
                        <div className="text-sm font-medium text-primary hover:underline">
                          {user.name}
                        </div>
                        <div className="text-xs text-muted-foreground">
                          {user.email}
                        </div>
                      </div>
                    </div>
                  </Link>
                </td>
                <td className="px-4 py-3">
                  <Link
                    to={`/users/profiles/${user.profileId}`}
                    className="rounded bg-purple-500/10 px-2 py-0.5 text-xs text-purple-400 hover:bg-purple-500/20"
                  >
                    {user.profileName}
                  </Link>
                </td>
                <td className="px-4 py-3">
                  <span className="text-xs text-muted-foreground">
                    {user.license || user.userType}
                  </span>
                </td>
                <td className="px-4 py-3">
                  <span
                    className={cn(
                      "text-xs",
                      user.lastLogin
                        ? isRecent(user.lastLogin)
                          ? "text-green-400"
                          : "text-muted-foreground"
                        : "text-red-400"
                    )}
                  >
                    {user.lastLogin
                      ? formatDate(user.lastLogin)
                      : "Never"}
                  </span>
                </td>
                <td className="px-4 py-3">
                  <span className="text-xs text-muted-foreground">
                    {user.roleName || "-"}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function formatDate(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const diff = now.getTime() - d.getTime();
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 30) return `${days} days ago`;
  return d.toLocaleDateString();
}

function isRecent(iso: string): boolean {
  const diff = Date.now() - new Date(iso).getTime();
  return diff < 7 * 24 * 60 * 60 * 1000; // within 7 days
}
