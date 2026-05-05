import { useEffect, useState } from "react";
import { useParams, Link } from "react-router";
import { createDataSDK } from "@salesforce/sdk-data";
import { Skeleton } from "../components/ui/skeleton";
import { Button } from "../components/ui/button";
import { fieldValue } from "../features/object-search/utils/fieldUtils";
import GET_ACCOUNT_DETAIL from "../api/account/query/getAccountDetail.graphql?raw";
import GET_CONTACTS from "../api/account/query/getAccountContacts.graphql?raw";
import GET_OPPS from "../api/account/query/getAccountOpportunities.graphql?raw";

type AccountDetail = any;
type ContactNode = any;
type OppNode = any;

async function fetchGraphQL(query: string, variables: Record<string, unknown>) {
  const sdk = await createDataSDK();
  const res = await sdk.graphql?.({ query, variables });
  if ((res as any)?.errors?.length) {
    throw new Error((res as any).errors.map((e: any) => e.message).join("; "));
  }
  return (res as any)?.data?.uiapi?.query;
}

// ── Status color config ────────────────────────────────────────────────────

type StatusConfig = { gradient: string; border: string; badge: string; dot: string };

const STATUS_CONFIG: Record<string, StatusConfig> = {
  Customer: { gradient: "from-emerald-950 to-slate-950", border: "border-emerald-500/20", badge: "bg-emerald-500/15 text-emerald-300 ring-1 ring-emerald-500/30", dot: "bg-emerald-400" },
  "Active Customer": { gradient: "from-emerald-950 to-slate-950", border: "border-emerald-500/20", badge: "bg-emerald-500/15 text-emerald-300 ring-1 ring-emerald-500/30", dot: "bg-emerald-400" },
  Prospect: { gradient: "from-blue-950 to-slate-950", border: "border-blue-500/20", badge: "bg-blue-500/15 text-blue-300 ring-1 ring-blue-500/30", dot: "bg-blue-400" },
  "At Risk": { gradient: "from-amber-950 to-slate-950", border: "border-amber-500/20", badge: "bg-amber-500/15 text-amber-300 ring-1 ring-amber-500/30", dot: "bg-amber-400" },
  "Former Customer": { gradient: "from-rose-950 to-slate-950", border: "border-rose-500/20", badge: "bg-rose-500/15 text-rose-300 ring-1 ring-rose-500/30", dot: "bg-rose-400" },
  Churned: { gradient: "from-rose-950 to-slate-950", border: "border-rose-500/20", badge: "bg-rose-500/15 text-rose-300 ring-1 ring-rose-500/30", dot: "bg-rose-400" },
};
const DEFAULT_STATUS: StatusConfig = { gradient: "from-slate-900 to-slate-950", border: "border-slate-600/20", badge: "bg-slate-500/15 text-slate-300 ring-1 ring-slate-500/30", dot: "bg-slate-400" };
const getStatusCfg = (s?: string | null) => (s && STATUS_CONFIG[s]) ? STATUS_CONFIG[s] : DEFAULT_STATUS;

// ── Sub-components ─────────────────────────────────────────────────────────

function GlassCard({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return (
    <div className={`bg-white/5 backdrop-blur-sm border border-white/10 rounded-2xl ${className}`}>
      {children}
    </div>
  );
}

function Field({ label, value, mono }: { label: string; value?: string | null; mono?: boolean }) {
  if (!value) return null;
  return (
    <div>
      <dt className="text-xs text-slate-500 mb-0.5">{label}</dt>
      <dd className={`text-sm text-slate-200 ${mono ? "font-mono" : ""}`}>{value}</dd>
    </div>
  );
}

function StageBadge({ stage }: { stage: string }) {
  const map: Record<string, string> = {
    "Closed Won": "bg-emerald-500/15 text-emerald-300 ring-1 ring-emerald-500/30",
    "Closed Lost": "bg-rose-500/15 text-rose-300 ring-1 ring-rose-500/30",
    Prospecting: "bg-slate-500/15 text-slate-300 ring-1 ring-slate-500/30",
    "Proposal/Price Quote": "bg-blue-500/15 text-blue-300 ring-1 ring-blue-500/30",
    "Negotiation/Review": "bg-amber-500/15 text-amber-300 ring-1 ring-amber-500/30",
  };
  return (
    <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${map[stage] ?? "bg-slate-500/15 text-slate-300 ring-1 ring-slate-500/30"}`}>
      {stage}
    </span>
  );
}

function HealthDisplay({ value }: { value: any }) {
  const raw = value?.value ?? value?.displayValue;
  if (!raw) return null;
  const n = parseFloat(String(raw));
  const color = isNaN(n) ? "text-slate-300"
    : n >= 80 ? "text-emerald-400"
    : n >= 60 ? "text-yellow-400"
    : n >= 40 ? "text-orange-400"
    : "text-rose-400";
  return <span className={`text-2xl font-bold ${color}`}>{value?.displayValue ?? raw}</span>;
}

function StatCard({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <GlassCard className="p-4">
      <div className="text-xs text-slate-500 mb-1">{label}</div>
      <div className="text-white font-semibold">{children}</div>
    </GlassCard>
  );
}

// ── Tabs ───────────────────────────────────────────────────────────────────

const TABS = ["Overview", "Team", "Deals", "Contacts", "Notes", "AI"] as const;
type Tab = typeof TABS[number];

// ── Main component ─────────────────────────────────────────────────────────

export default function AccountDetailPage() {
  const { recordId } = useParams<{ recordId: string }>();
  const [account, setAccount] = useState<AccountDetail>(null);
  const [contacts, setContacts] = useState<ContactNode[]>([]);
  const [opps, setOpps] = useState<OppNode[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [tab, setTab] = useState<Tab>("Overview");
  const [aiPrompt, setAiPrompt] = useState("");
  const [aiResponse, setAiResponse] = useState("");
  const [aiLoading, setAiLoading] = useState(false);

  useEffect(() => {
    if (!recordId) return;
    (async () => {
      try {
        const [acctData, contactData, oppData] = await Promise.all([
          fetchGraphQL(GET_ACCOUNT_DETAIL, { id: recordId }),
          fetchGraphQL(GET_CONTACTS, { accountId: recordId }),
          fetchGraphQL(GET_OPPS, { accountId: recordId }),
        ]);
        setAccount(acctData?.Account?.edges?.[0]?.node ?? null);
        setContacts((contactData?.Contact?.edges ?? []).map((e: any) => e?.node).filter(Boolean));
        setOpps((oppData?.Opportunity?.edges ?? []).map((e: any) => e?.node).filter(Boolean));
      } catch (e: any) {
        setError(e?.message ?? "Failed to load account");
      } finally {
        setLoading(false);
      }
    })();
  }, [recordId]);

  const fv = (field: any) => fieldValue(field) ?? null;

  const name = fv(account?.Name) ?? "Account";
  const status = fv(account?.Account_Status__c);
  const cfg = getStatusCfg(status);
  const openOpps = opps.filter((o: any) => !o?.IsClosed?.value);
  const closedWon = opps.filter((o: any) => o?.IsClosed?.value && o?.IsWon?.value);

  async function handleAiPrompt() {
    if (!aiPrompt.trim()) return;
    setAiLoading(true);
    setAiResponse("");
    try {
      await new Promise((r) => setTimeout(r, 800));
      setAiResponse(`AI response for "${aiPrompt}" on ${name} — wire this up to your backend AI service.`);
    } finally {
      setAiLoading(false);
    }
  }

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 p-6">
        <Skeleton className="h-6 w-32 bg-white/5 mb-6" />
        <Skeleton className="h-12 w-64 bg-white/5 mb-2" />
        <Skeleton className="h-4 w-48 bg-white/5 mb-8" />
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          {Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-20 rounded-2xl bg-white/5" />)}
        </div>
        <Skeleton className="h-96 rounded-2xl bg-white/5" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-950 to-slate-900 p-6">
        <p className="text-rose-400 mb-4">{error}</p>
        <Link to="/accounts" className="text-slate-400 hover:text-white text-sm underline">← Back to accounts</Link>
      </div>
    );
  }

  return (
    <div className={`min-h-screen bg-gradient-to-br ${cfg.gradient} via-slate-950`}>

      {/* Hero header */}
      <div className="px-4 sm:px-6 pt-6 pb-4 max-w-7xl mx-auto">
        <Link to="/accounts" className="inline-flex items-center gap-1 text-slate-400 hover:text-white text-sm mb-4 transition-colors">
          ← My Accounts
        </Link>

        <div className="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-3 flex-wrap mb-2">
              <h1 className="text-2xl sm:text-4xl font-bold text-white">{name}</h1>
              {status && (
                <span className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-sm font-medium ${cfg.badge}`}>
                  <span className={`w-2 h-2 rounded-full ${cfg.dot}`} />
                  {status}
                </span>
              )}
              {fv(account?.Account_Tier__c) && (
                <span className="px-3 py-1 rounded-full text-sm font-medium bg-violet-500/15 text-violet-300 ring-1 ring-violet-500/30">
                  {fv(account?.Account_Tier__c)}
                </span>
              )}
            </div>
            <div className="flex flex-wrap items-center gap-2 text-sm text-slate-400">
              {fv(account?.AccountNumber) && <span className="font-mono"># {fv(account?.AccountNumber)}</span>}
              {fv(account?.Segment__c) && <><span>·</span><span>{fv(account?.Segment__c)}</span></>}
              {fv(account?.Region__c) && <><span>·</span><span>{fv(account?.Region__c)}</span></>}
              {fv(account?.Business_Type__c) && <><span>·</span><span>{fv(account?.Business_Type__c)}</span></>}
            </div>
          </div>
          <div className="text-right flex-shrink-0">
            <HealthDisplay value={account?.Account_Health_Score__c} />
            {account?.Account_Health_Score__c && <div className="text-xs text-slate-500 mt-0.5">Health Score</div>}
          </div>
        </div>
      </div>

      {/* Stats strip */}
      <div className="px-4 sm:px-6 pb-4 max-w-7xl mx-auto">
        <div className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-6 gap-3">
          {account?.ARR__c?.displayValue && <StatCard label="ARR">{account.ARR__c.displayValue}</StatCard>}
          {account?.AUM__c?.displayValue && <StatCard label="AUM">{account.AUM__c.displayValue}</StatCard>}
          {account?.MRR__c?.displayValue && <StatCard label="MRR">{account.MRR__c.displayValue}</StatCard>}
          <StatCard label="Open Deals">{openOpps.length}</StatCard>
          <StatCard label="Closed Won">{closedWon.length}</StatCard>
          <StatCard label="Contacts">{contacts.length}</StatCard>
        </div>
      </div>

      {/* Tab bar */}
      <div className="px-4 sm:px-6 max-w-7xl mx-auto">
        <div className="flex gap-1 bg-white/5 backdrop-blur-sm rounded-xl p-1 border border-white/10 w-fit mb-4 overflow-x-auto">
          {TABS.map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`px-4 py-1.5 rounded-lg text-sm font-medium transition-all whitespace-nowrap ${
                tab === t
                  ? "bg-white/15 text-white shadow-sm"
                  : "text-slate-400 hover:text-white hover:bg-white/8"
              }`}
            >
              {t}{t === "Deals" ? ` (${opps.length})` : t === "Contacts" ? ` (${contacts.length})` : ""}
            </button>
          ))}
        </div>
      </div>

      {/* Tab content */}
      <div className="px-4 sm:px-6 pb-8 max-w-7xl mx-auto">

        {/* ── Overview ── */}
        {tab === "Overview" && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <GlassCard className="p-5">
              <h3 className="text-white font-semibold mb-4">Account Details</h3>
              <dl className="grid grid-cols-2 gap-x-6 gap-y-4">
                <Field label="Account Owner" value={fv(account?.Owner?.Name)} />
                <Field label="Account Number" value={fv(account?.AccountNumber)} mono />
                <Field label="Phone" value={fv(account?.Phone)} />
                <Field label="Website" value={fv(account?.Website)} />
                <Field label="Industry" value={fv(account?.Industry)} />
                <Field label="Type" value={fv(account?.Type)} />
                <Field label="Employees" value={fv(account?.NumberOfEmployees)} />
                <Field label="Number of Bankers" value={fv(account?.Number_of_Bankers__c)} />
                <Field label="Estimated TAM" value={account?.Estimated_TAM__c?.displayValue ?? fv(account?.Estimated_TAM__c)} />
                <Field label="TCV" value={account?.TCV__c?.displayValue} />
                <Field label="Renewal Date" value={account?.Renewal_Date__c?.displayValue} />
                <Field label="Active Contracts" value={fv(account?.Active_Contracts__c)} />
                <Field label="Must Win" value={fv(account?.Must_Win__c)} />
                <Field label="Auto Renew" value={fv(account?.Auto_Renew__c)} />
              </dl>
            </GlassCard>

            <GlassCard className="p-5">
              <h3 className="text-white font-semibold mb-4">Description</h3>
              <p className="text-slate-400 text-sm leading-relaxed">
                {fv(account?.Description) ?? "No description provided."}
              </p>
              {(fv(account?.BillingCity) || fv(account?.BillingCountry)) && (
                <>
                  <h3 className="text-white font-semibold mt-5 mb-3">Location</h3>
                  <dl className="space-y-2">
                    <Field label="Billing Address" value={[
                      fv(account?.BillingStreet),
                      fv(account?.BillingCity),
                      fv(account?.BillingState),
                      fv(account?.BillingPostalCode),
                      fv(account?.BillingCountry),
                    ].filter(Boolean).join(", ")} />
                  </dl>
                </>
              )}
            </GlassCard>
          </div>
        )}

        {/* ── Team ── */}
        {tab === "Team" && (
          <GlassCard className="p-5">
            <h3 className="text-white font-semibold mb-4">Team & Ownership</h3>
            <dl className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-8 gap-y-5">
              <Field label="Account Owner" value={fv(account?.Owner?.Name)} />
              <Field label="Post-Sales Owner" value={fv(account?.Post_Sales_Owner__c)} />
              <Field label="GTM Associate" value={fv(account?.GTM_Associate__c)} />
              <Field label="GTM Associate Owner" value={fv(account?.GTM_Associate_Owner__c)} />
              <Field label="GTM Strategy Owner" value={fv(account?.GTM_Strategy_Owner__c)} />
              <Field label="Pod" value={fv(account?.Pod__c)} />
              <Field label="Champions" value={fv(account?.Champions__c)} />
              <Field label="Last PS Touchpoint" value={account?.Last_PS_Touchpoint__c?.displayValue ?? fv(account?.Last_PS_Touchpoint__c)} />
            </dl>
          </GlassCard>
        )}

        {/* ── Deals ── */}
        {tab === "Deals" && (
          <GlassCard className="p-5">
            {opps.length === 0 ? (
              <p className="text-slate-500 text-sm text-center py-8">No opportunities found for this account.</p>
            ) : (
              <div className="divide-y divide-white/8">
                {opps.map((o: any, i: number) => (
                  <div key={o?.Id ?? i} className="py-4 flex items-center justify-between gap-4">
                    <div>
                      <div className="text-white font-medium text-sm">{fv(o.Name) ?? "—"}</div>
                      <div className="text-slate-500 text-xs mt-0.5">
                        Close: {o?.CloseDate?.displayValue ?? "—"}
                      </div>
                    </div>
                    <div className="flex items-center gap-3 flex-shrink-0">
                      <span className="text-white/90 font-semibold text-sm">{o?.Amount?.displayValue ?? "—"}</span>
                      <StageBadge stage={fv(o.StageName) ?? ""} />
                    </div>
                  </div>
                ))}
              </div>
            )}
          </GlassCard>
        )}

        {/* ── Contacts ── */}
        {tab === "Contacts" && (
          <GlassCard className="p-5">
            {contacts.length === 0 ? (
              <p className="text-slate-500 text-sm text-center py-8">No contacts found for this account.</p>
            ) : (
              <div className="divide-y divide-white/8">
                {contacts.map((c: any, i: number) => (
                  <div key={c?.Id ?? i} className="py-4 flex items-center justify-between gap-4">
                    <div className="flex items-center gap-3">
                      <div className="w-9 h-9 rounded-xl bg-white/10 text-white flex items-center justify-center text-sm font-semibold flex-shrink-0 ring-1 ring-white/15">
                        {(fv(c.Name) ?? "?").charAt(0)}
                      </div>
                      <div>
                        <div className="text-white font-medium text-sm">{fv(c.Name) ?? "—"}</div>
                        <div className="text-slate-500 text-xs">
                          {[fv(c.Title), fv(c.Department)].filter(Boolean).join(" · ") || "—"}
                        </div>
                      </div>
                    </div>
                    <div className="text-right text-xs text-slate-400">
                      {fv(c.Email) && <a href={`mailto:${fv(c.Email)}`} className="underline block hover:text-white">{fv(c.Email)}</a>}
                      {fv(c.Phone) && <div className="mt-0.5">{fv(c.Phone)}</div>}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </GlassCard>
        )}

        {/* ── Notes ── */}
        {tab === "Notes" && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <GlassCard className="p-5">
              <h3 className="text-white font-semibold mb-3">Next Steps</h3>
              <p className="text-slate-400 text-sm leading-relaxed whitespace-pre-wrap">
                {fv(account?.NextSteps__c) ?? "No next steps recorded."}
              </p>
            </GlassCard>
            <GlassCard className="p-5">
              <h3 className="text-white font-semibold mb-3">Notes</h3>
              <p className="text-slate-400 text-sm leading-relaxed whitespace-pre-wrap">
                {fv(account?.Notes__c) ?? "No notes."}
              </p>
            </GlassCard>
            <GlassCard className="p-5 lg:col-span-2">
              <h3 className="text-white font-semibold mb-3">Running Notes</h3>
              <p className="text-slate-400 text-sm leading-relaxed whitespace-pre-wrap">
                {fv(account?.Running_Notes__c) ?? "No running notes."}
              </p>
            </GlassCard>
          </div>
        )}

        {/* ── AI ── */}
        {tab === "AI" && (
          <GlassCard className="p-5">
            <h3 className="text-white font-semibold mb-4">Ask AI about this account</h3>
            <div className="flex flex-wrap gap-2 mb-4">
              {["Summarize this account", "What are the risks?", "Draft a follow-up email", "What's the best next step?", "Upsell opportunities?"].map((p) => (
                <button
                  key={p}
                  onClick={() => setAiPrompt(p)}
                  className="px-3 py-1.5 rounded-full border border-white/15 text-slate-300 text-sm hover:bg-white/10 hover:text-white transition-colors"
                >
                  {p}
                </button>
              ))}
            </div>
            <div className="flex gap-2">
              <input
                type="text"
                value={aiPrompt}
                onChange={(e) => setAiPrompt(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && handleAiPrompt()}
                placeholder="Ask anything about this account..."
                className="flex-1 bg-white/5 border border-white/10 rounded-xl px-4 py-2.5 text-sm text-white placeholder:text-slate-500 focus:outline-none focus:ring-2 focus:ring-white/20"
              />
              <Button
                onClick={handleAiPrompt}
                disabled={aiLoading || !aiPrompt.trim()}
                className="bg-white/10 hover:bg-white/20 text-white border border-white/15 rounded-xl px-4"
              >
                {aiLoading ? "Thinking…" : "Ask"}
              </Button>
            </div>
            {aiResponse && (
              <div className="mt-4 rounded-xl bg-white/5 border border-white/10 p-4 text-slate-300 text-sm whitespace-pre-wrap leading-relaxed">
                {aiResponse}
              </div>
            )}
          </GlassCard>
        )}

      </div>
    </div>
  );
}
