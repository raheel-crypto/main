// @ts-ignore - Salesforce module resolved at LWR runtime
import sfUserId from "@salesforce/user/Id";
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { searchAccounts } from "../api/account/accountSearchService";
import { fieldValue } from "../features/object-search/utils/fieldUtils";
import { Card } from "../components/ui/card";
import { Badge } from "../components/ui/badge";
import { Skeleton } from "../components/ui/skeleton";
import { SearchBar } from "../features/object-search/components/SearchBar";

type AccountNode = any;

function revenueSegment(revenue: number | null): { label: string; className: string } | null {
  if (revenue === null) return null;
  if (revenue > 1_000_000) return { label: "Enterprise", className: "bg-green-100 text-green-800" };
  if (revenue > 100_000) return { label: "Mid-market", className: "bg-yellow-100 text-yellow-800" };
  return { label: "SMB", className: "bg-gray-100 text-gray-700" };
}

export default function AccountTilesPage() {
  const [accounts, setAccounts] = useState<AccountNode[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const where = sfUserId ? { OwnerId: { eq: sfUserId } } : undefined;
        const res = await searchAccounts({ where, first: 50 });
        const nodes = (res?.edges ?? []).map((e: any) => e?.node).filter(Boolean);
        setAccounts(nodes);
      } catch {
        // keep empty on error
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const filtered = search.trim()
    ? accounts.filter((a: any) => {
        const name = (fieldValue(a.Name) ?? "").toLowerCase();
        const industry = (fieldValue(a.Industry) ?? "").toLowerCase();
        const q = search.toLowerCase();
        return name.includes(q) || industry.includes(q);
      })
    : accounts;

  return (
    <div className="p-4 sm:p-6">
      <div className="max-w-7xl mx-auto">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 mb-6">
          <div>
            <h1 className="text-2xl sm:text-3xl font-semibold">My Accounts</h1>
            {!loading && (
              <p className="text-sm text-muted-foreground mt-1">
                {accounts.length} account{accounts.length !== 1 ? "s" : ""} assigned to you
              </p>
            )}
          </div>
          <div className="w-full sm:w-72">
            <SearchBar
              placeholder="Filter by name or industry..."
              value={search}
              handleChange={setSearch}
            />
          </div>
        </div>

        {loading ? (
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3">
            {Array.from({ length: 6 }).map((_, i) => (
              <Skeleton key={i} className="h-36 rounded-lg" />
            ))}
          </div>
        ) : filtered.length === 0 ? (
          <div className="text-center py-16 text-muted-foreground">
            {search ? "No accounts match your search." : "No accounts are assigned to you."}
          </div>
        ) : (
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 auto-rows-fr">
            {filtered.map((a: any, idx: number) => {
              const id = a?.Id as string;
              const name = fieldValue(a.Name) ?? "—";
              const industry = fieldValue(a.Industry) ?? "";
              const type = fieldValue(a.Type) ?? "";
              const revenue = a?.AnnualRevenue?.value as number | null ?? null;
              const revenueDisplay = a?.AnnualRevenue?.displayValue ?? "";
              const segment = revenueSegment(revenue);

              return (
                <Link key={id || `acct-${idx}`} to={`/accounts/${id}`} className="block group">
                  <Card className="h-full p-4 sm:p-5 hover:shadow-xl transition-all rounded-lg group-hover:border-primary/40">
                    <div className="flex items-start gap-3 mb-4">
                      <div className="flex-shrink-0 w-10 h-10 rounded-full bg-primary/10 text-primary flex items-center justify-center font-semibold text-sm">
                        {name.charAt(0)}
                      </div>
                      <div className="min-w-0">
                        <h2 className="text-base font-medium truncate">{name}</h2>
                        <p className="text-xs text-muted-foreground truncate">
                          {[industry, type].filter(Boolean).join(" · ") || "—"}
                        </p>
                      </div>
                    </div>

                    <div className="flex items-center justify-between pt-3 border-t border-border/50">
                      <div>
                        <div className="text-xs text-muted-foreground">Annual Revenue</div>
                        <div className="text-sm font-semibold">{revenueDisplay || "—"}</div>
                      </div>
                      {segment && (
                        <Badge className={segment.className}>{segment.label}</Badge>
                      )}
                    </div>
                  </Card>
                </Link>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
