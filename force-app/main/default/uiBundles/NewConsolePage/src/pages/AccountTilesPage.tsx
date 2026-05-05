import { useEffect, useState } from "react";
import { Link } from "react-router";
import { searchAccounts } from "../api/account/accountSearchService";
import { fieldValue } from "../features/object-search/utils/fieldUtils";
import { Skeleton } from "../components/ui/skeleton";

const sfUserId: string | undefined = (globalThis as any).SFDC_ENV?.userId;

type AccountNode = any;

type StatusConfig = {
  gradient: string;
  border: string;
  badge: string;
  glow: string;
  dot: string;
};

const STATUS_CONFIG: Record<string, StatusConfig> = {
  Customer: {
    gradient: "from-emerald-950/90 via-emerald-900/30 to-slate-950/90",
    border: "border-emerald-500/25 hover:border-emerald-400/50",
    badge: "bg-emerald-500/15 text-emerald-300 ring-1 ring-emerald-500/30",
    glow: "hover:shadow-emerald-900/40",
    dot: "bg-emerald-400",
  },
  "Active Customer": {
    gradient: "from-emerald-950/90 via-emerald-900/30 to-slate-950/90",
    border: "border-emerald-500/25 hover:border-emerald-400/50",
    badge: "bg-emerald-500/15 text-emerald-300 ring-1 ring-emerald-500/30",
    glow: "hover:shadow-emerald-900/40",
    dot: "bg-emerald-400",
  },
  Prospect: {
    gradient: "from-blue-950/90 via-blue-900/30 to-slate-950/90",
    border: "border-blue-500/25 hover:border-blue-400/50",
    badge: "bg-blue-500/15 text-blue-300 ring-1 ring-blue-500/30",
    glow: "hover:shadow-blue-900/40",
    dot: "bg-blue-400",
  },
  "At Risk": {
    gradient: "from-amber-950/90 via-amber-900/30 to-slate-950/90",
    border: "border-amber-500/25 hover:border-amber-400/50",
    badge: "bg-amber-500/15 text-amber-300 ring-1 ring-amber-500/30",
    glow: "hover:shadow-amber-900/40",
    dot: "bg-amber-400",
  },
  "Former Customer": {
    gradient: "from-rose-950/90 via-rose-900/30 to-slate-950/90",
    border: "border-rose-500/25 hover:border-rose-400/50",
    badge: "bg-rose-500/15 text-rose-300 ring-1 ring-rose-500/30",
    glow: "hover:shadow-rose-900/40",
    dot: "bg-rose-400",
  },
  Churned: {
    gradient: "from-rose-950/90 via-rose-900/30 to-slate-950/90",
    border: "border-rose-500/25 hover:border-rose-400/50",
    badge: "bg-rose-500/15 text-rose-300 ring-1 ring-rose-500/30",
    glow: "hover:shadow-rose-900/40",
    dot: "bg-rose-400",
  },
};

const DEFAULT_STATUS: StatusConfig = {
  gradient: "from-slate-800/90 via-slate-800/30 to-slate-950/90",
  border: "border-slate-600/25 hover:border-slate-500/50",
  badge: "bg-slate-500/15 text-slate-300 ring-1 ring-slate-500/30",
  glow: "hover:shadow-slate-900/40",
  dot: "bg-slate-400",
};

function getStatusConfig(status: string | null | undefined): StatusConfig {
  if (!status) return DEFAULT_STATUS;
  return STATUS_CONFIG[status] ?? DEFAULT_STATUS;
}

function healthColor(score: string | number | null | undefined): string {
  if (score == null) return "text-slate-400";
  const n = typeof score === "string" ? parseFloat(score) : score;
  if (isNaN(n)) return "text-slate-400";
  if (n >= 80) return "text-emerald-400";
  if (n >= 60) return "text-yellow-400";
  if (n >= 40) return "text-orange-400";
  return "text-rose-400";
}

function HealthScore({ value }: { value: any }) {
  const display = value?.displayValue ?? value?.value;
  if (!display) return null;
  const numericScore = parseFloat(String(value?.value ?? ""));
  return (
    <span className={`text-xs font-semibold tabular-nums ${healthColor(numericScore)}`}>
      HS {display}
    </span>
  );
}

function AccountCard({ account }: { account: AccountNode }) {
  const id = account?.Id as string;
  const name = fieldValue(account?.Name) ?? "—";
  const accountNumber = fieldValue(account?.AccountNumber);
  const status = fieldValue(account?.Account_Status__c);
  const tier = fieldValue(account?.Account_Tier__c);
  const segment = fieldValue(account?.Segment__c);
  const region = fieldValue(account?.Region__c);
  const arr = account?.ARR__c?.displayValue ?? fieldValue(account?.AnnualRevenue);
  const businessType = fieldValue(account?.Business_Type__c) ?? fieldValue(account?.Type);
  const cfg = getStatusConfig(status);

  return (
    <Link to={`/accounts/${id}`} className="block group">
      <div
        className={`
          relative h-full rounded-2xl bg-gradient-to-br ${cfg.gradient}
          backdrop-blur-xl border ${cfg.border}
          shadow-xl ${cfg.glow}
          transition-all duration-300 hover:scale-[1.02] hover:shadow-2xl
          p-5 flex flex-col gap-3
        `}
      >
        {/* Subtle glass sheen */}
        <div className="absolute inset-0 rounded-2xl bg-white/[0.02] pointer-events-none" />

        {/* Header row */}
        <div className="flex items-start gap-3">
          <div className="flex-shrink-0 w-11 h-11 rounded-xl bg-white/10 backdrop-blur-sm flex items-center justify-center text-white font-bold text-base ring-1 ring-white/20">
            {name.charAt(0).toUpperCase()}
          </div>
          <div className="min-w-0 flex-1">
            <h2 className="text-white font-semibold text-sm leading-tight truncate group-hover:text-white/90">
              {name}
            </h2>
            {accountNumber && (
              <p className="text-slate-400 text-xs mt-0.5 font-mono">{accountNumber}</p>
            )}
          </div>
        </div>

        {/* Badges row */}
        <div className="flex flex-wrap items-center gap-1.5">
          {status && (
            <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${cfg.badge}`}>
              <span className={`w-1.5 h-1.5 rounded-full ${cfg.dot}`} />
              {status}
            </span>
          )}
          {tier && (
            <span className="px-2 py-0.5 rounded-full text-xs font-medium bg-violet-500/15 text-violet-300 ring-1 ring-violet-500/30">
              {tier}
            </span>
          )}
          <HealthScore value={account?.Account_Health_Score__c} />
        </div>

        {/* Divider */}
        <div className="border-t border-white/8" />

        {/* Meta row */}
        <div className="flex items-end justify-between gap-2">
          <div className="min-w-0">
            {(segment || region) && (
              <p className="text-slate-400 text-xs truncate">
                {[segment, region].filter(Boolean).join(" · ")}
              </p>
            )}
            {businessType && (
              <p className="text-slate-500 text-xs truncate">{businessType}</p>
            )}
          </div>
          {arr && (
            <div className="text-right flex-shrink-0">
              <div className="text-xs text-slate-500 mb-0.5">ARR</div>
              <div className="text-white/90 text-sm font-semibold">{arr}</div>
            </div>
          )}
        </div>
      </div>
    </Link>
  );
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
        // keep empty
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const filtered = search.trim()
    ? accounts.filter((a: any) => {
        const q = search.toLowerCase();
        return (
          (fieldValue(a.Name) ?? "").toLowerCase().includes(q) ||
          (fieldValue(a.Segment__c) ?? "").toLowerCase().includes(q) ||
          (fieldValue(a.Region__c) ?? "").toLowerCase().includes(q) ||
          (fieldValue(a.Account_Status__c) ?? "").toLowerCase().includes(q)
        );
      })
    : accounts;

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 p-4 sm:p-6">
      <div className="max-w-7xl mx-auto">

        {/* Header */}
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-8">
          <div>
            <h1 className="text-2xl sm:text-3xl font-bold text-white">My Accounts</h1>
            {!loading && (
              <p className="text-slate-400 text-sm mt-1">
                {accounts.length} account{accounts.length !== 1 ? "s" : ""} assigned to you
              </p>
            )}
          </div>
          <div className="relative w-full sm:w-72">
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Filter accounts..."
              className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-2.5 text-sm text-white placeholder:text-slate-500 focus:outline-none focus:ring-2 focus:ring-white/20 backdrop-blur-sm"
            />
          </div>
        </div>

        {/* Grid */}
        {loading ? (
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3">
            {Array.from({ length: 6 }).map((_, i) => (
              <Skeleton key={i} className="h-44 rounded-2xl bg-white/5" />
            ))}
          </div>
        ) : filtered.length === 0 ? (
          <div className="text-center py-20 text-slate-500">
            {search ? "No accounts match your search." : "No accounts are assigned to you."}
          </div>
        ) : (
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 auto-rows-fr">
            {filtered.map((a: any, idx: number) => (
              <AccountCard key={a?.Id ?? `acct-${idx}`} account={a} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
