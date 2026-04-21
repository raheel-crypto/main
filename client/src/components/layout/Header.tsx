import { cn } from "../../lib/utils";
import { api } from "../../lib/api";

interface HeaderProps {
  user: {
    name: string;
    email: string;
    orgId: string;
    instanceUrl: string;
    environment: "production" | "sandbox";
  };
}

export function Header({ user }: HeaderProps) {
  const orgDomain = user.instanceUrl.replace("https://", "").split(".")[0];
  const isSandbox = user.environment === "sandbox";

  const handleLogout = async () => {
    await api.logout().catch(() => {});
    window.location.href = "/";
  };

  return (
    <header className="flex h-14 items-center justify-between border-b border-border px-6">
      <div className="flex items-center gap-3">
        <span className="text-sm text-muted-foreground">Connected to</span>
        <span
          className={cn(
            "rounded-md px-2 py-1 text-xs font-medium",
            isSandbox
              ? "bg-amber-500/10 text-amber-400"
              : "bg-sf-blue/10 text-sf-blue"
          )}
        >
          {orgDomain}
        </span>
        <span
          className={cn(
            "rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider",
            isSandbox
              ? "bg-amber-500/10 text-amber-400 border border-amber-500/20"
              : "bg-green-500/10 text-green-400 border border-green-500/20"
          )}
        >
          {isSandbox ? "Sandbox" : "Production"}
        </span>
      </div>
      <div className="flex items-center gap-4">
        <div className="text-right">
          <div className="text-sm font-medium text-foreground">
            {user.name}
          </div>
          <div className="text-xs text-muted-foreground">{user.email}</div>
        </div>
        <div className="flex h-8 w-8 items-center justify-center rounded-full bg-primary text-xs font-medium text-primary-foreground">
          {user.name
            .split(" ")
            .map((n) => n[0])
            .join("")
            .toUpperCase()
            .slice(0, 2)}
        </div>
        <button
          onClick={handleLogout}
          className="rounded-md border border-border px-3 py-1.5 text-xs text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
          title="Log out and switch org"
        >
          Switch Org
        </button>
      </div>
    </header>
  );
}
