"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  BarChart3,
  Calendar,
  Users,
  Settings,
  LogOut,
  ChevronDown,
  AlertTriangle,
} from "lucide-react";
import type { User } from "@/lib/types";
import type { User as AuthUser } from "@supabase/supabase-js";

interface DashboardNavProps {
  user: User | null;
  authUser: AuthUser;
}

const navItems = [
  { href: "/dashboard", label: "Overview", icon: BarChart3 },
  { href: "/dashboard/week", label: "This Week", icon: Calendar },
  { href: "/dashboard/team", label: "Team", icon: Users, managerOnly: true },
  { href: "/dashboard/settings", label: "Settings", icon: Settings },
];

export function DashboardNav({ user, authUser }: DashboardNavProps) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();

  const isManager = user?.role === "manager" || user?.role === "admin";

  const handleSignOut = async () => {
    await supabase.auth.signOut();
    router.push("/auth/login");
    router.refresh();
  };

  return (
    <header className="border-b border-border bg-card sticky top-0 z-40">
      <div className="max-w-7xl mx-auto px-4">
        <div className="flex items-center justify-between h-14">
          {/* Logo & Nav */}
          <div className="flex items-center gap-8">
            <Link href="/dashboard" className="flex items-center gap-2">
              <div className="w-8 h-8 rounded-lg bg-primary flex items-center justify-center">
                <BarChart3 className="w-4 h-4 text-primary-foreground" />
              </div>
              <span className="font-semibold hidden sm:block">Pipeline Review</span>
            </Link>

            <nav className="flex items-center gap-1">
              {navItems
                .filter((item) => !item.managerOnly || isManager)
                .map((item) => {
                  const isActive =
                    pathname === item.href ||
                    (item.href !== "/dashboard" && pathname.startsWith(item.href));
                  return (
                    <Link
                      key={item.href}
                      href={item.href}
                      className={`flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                        isActive
                          ? "bg-primary/10 text-primary"
                          : "text-muted-foreground hover:text-foreground hover:bg-accent"
                      }`}
                    >
                      <item.icon className="w-4 h-4" />
                      <span className="hidden md:block">{item.label}</span>
                    </Link>
                  );
                })}
            </nav>
          </div>

          {/* User Menu */}
          <div className="flex items-center gap-3">
            {isManager && (
              <Link href="/dashboard/team">
                <Button variant="ghost" size="sm" className="gap-2 text-destructive">
                  <AlertTriangle className="w-4 h-4" />
                  <span className="hidden sm:block">Red Flags</span>
                </Button>
              </Link>
            )}

            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" size="sm" className="gap-2">
                  <div className="w-6 h-6 rounded-full bg-primary/10 flex items-center justify-center text-xs font-medium text-primary">
                    {(user?.full_name || authUser.email)?.[0]?.toUpperCase()}
                  </div>
                  <span className="hidden sm:block max-w-[120px] truncate">
                    {user?.full_name || authUser.email}
                  </span>
                  <ChevronDown className="w-4 h-4 text-muted-foreground" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-48">
                <div className="px-2 py-1.5 text-sm">
                  <div className="font-medium truncate">{user?.full_name}</div>
                  <div className="text-muted-foreground text-xs truncate">
                    {authUser.email}
                  </div>
                </div>
                <DropdownMenuSeparator />
                <DropdownMenuItem asChild>
                  <Link href="/dashboard/settings" className="cursor-pointer">
                    <Settings className="w-4 h-4 mr-2" />
                    Settings
                  </Link>
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  onClick={handleSignOut}
                  className="text-destructive focus:text-destructive cursor-pointer"
                >
                  <LogOut className="w-4 h-4 mr-2" />
                  Sign out
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      </div>
    </header>
  );
}
