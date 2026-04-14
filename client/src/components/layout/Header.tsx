interface HeaderProps {
  user: {
    name: string;
    email: string;
    orgId: string;
    instanceUrl: string;
  };
}

export function Header({ user }: HeaderProps) {
  const orgDomain = user.instanceUrl.replace("https://", "").split(".")[0];

  return (
    <header className="flex h-14 items-center justify-between border-b border-border px-6">
      <div className="flex items-center gap-3">
        <span className="text-sm text-muted-foreground">Connected to</span>
        <span className="rounded-md bg-sf-blue/10 px-2 py-1 text-xs font-medium text-sf-blue">
          {orgDomain}
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
      </div>
    </header>
  );
}
