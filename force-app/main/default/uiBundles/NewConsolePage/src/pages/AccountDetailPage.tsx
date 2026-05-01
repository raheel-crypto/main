import { useEffect, useState } from "react";
import { useParams, Link } from "react-router";
import { createDataSDK } from "@salesforce/sdk-data";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Badge } from "../components/ui/badge";
import { Skeleton } from "../components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../components/ui/tabs";
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
  const res = await sdk.graphql?.(query, variables);
  if ((res as any)?.errors?.length) {
    throw new Error((res as any).errors.map((e: any) => e.message).join("; "));
  }
  return (res as any)?.data?.uiapi?.query;
}

function StageBadge({ stage }: { stage: string }) {
  const colorMap: Record<string, string> = {
    "Closed Won": "bg-green-100 text-green-800",
    "Closed Lost": "bg-red-100 text-red-800",
    "Prospecting": "bg-gray-100 text-gray-700",
    "Proposal/Price Quote": "bg-blue-100 text-blue-800",
    "Negotiation/Review": "bg-yellow-100 text-yellow-800",
  };
  return (
    <Badge className={colorMap[stage] ?? "bg-gray-100 text-gray-700"}>{stage}</Badge>
  );
}

function AccountHealthBadge({ contacts, opps }: { contacts: ContactNode[]; opps: OppNode[] }) {
  const openOpps = opps.filter((o: any) => !o?.IsClosed?.value);
  if (contacts.length > 0 && openOpps.length > 0) {
    return <Badge className="bg-green-100 text-green-800">Healthy</Badge>;
  }
  if (contacts.length > 0 || openOpps.length > 0) {
    return <Badge className="bg-yellow-100 text-yellow-800">Needs attention</Badge>;
  }
  return <Badge className="bg-red-100 text-red-800">At risk</Badge>;
}

export default function AccountDetailPage() {
  const { recordId } = useParams<{ recordId: string }>();
  const [account, setAccount] = useState<AccountDetail>(null);
  const [contacts, setContacts] = useState<ContactNode[]>([]);
  const [opps, setOpps] = useState<OppNode[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [aiPrompt, setAiPrompt] = useState("");
  const [aiResponse, setAiResponse] = useState("");
  const [aiLoading, setAiLoading] = useState(false);

  useEffect(() => {
    if (!recordId) return;
    (async () => {
      try {
        const [accountData, contactData, oppData] = await Promise.all([
          fetchGraphQL(GET_ACCOUNT_DETAIL, { id: recordId }),
          fetchGraphQL(GET_CONTACTS, { accountId: recordId }),
          fetchGraphQL(GET_OPPS, { accountId: recordId }),
        ]);
        setAccount(accountData?.Account?.edges?.[0]?.node ?? null);
        setContacts((contactData?.Contact?.edges ?? []).map((e: any) => e?.node).filter(Boolean));
        setOpps((oppData?.Opportunity?.edges ?? []).map((e: any) => e?.node).filter(Boolean));
      } catch (e: any) {
        setError(e?.message ?? "Failed to load account");
      } finally {
        setLoading(false);
      }
    })();
  }, [recordId]);

  const name = fieldValue(account?.Name) ?? "Account";
  const industry = fieldValue(account?.Industry) ?? "";
  const type = fieldValue(account?.Type) ?? "";
  const revenue = account?.AnnualRevenue?.displayValue ?? "";
  const employees = account?.NumberOfEmployees?.displayValue ?? "";
  const website = fieldValue(account?.Website) ?? "";
  const phone = fieldValue(account?.Phone) ?? "";
  const description = fieldValue(account?.Description) ?? "";
  const billingCity = fieldValue(account?.BillingCity) ?? "";
  const billingState = fieldValue(account?.BillingState) ?? "";
  const billingCountry = fieldValue(account?.BillingCountry) ?? "";
  const location = [billingCity, billingState, billingCountry].filter(Boolean).join(", ");

  const openOpps = opps.filter((o: any) => !o?.IsClosed?.value);
  const closedWon = opps.filter((o: any) => o?.IsClosed?.value && o?.IsWon?.value);

  async function handleAiPrompt() {
    if (!aiPrompt.trim()) return;
    setAiLoading(true);
    setAiResponse("");
    try {
      // Placeholder: replace with your AI endpoint
      await new Promise((r) => setTimeout(r, 800));
      setAiResponse(
        `AI response for "${aiPrompt}" on ${name} — wire this up to your backend AI service.`
      );
    } finally {
      setAiLoading(false);
    }
  }

  if (loading) {
    return (
      <div className="max-w-6xl mx-auto p-6 space-y-4">
        <Skeleton className="h-8 w-64" />
        <Skeleton className="h-4 w-40" />
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4 mt-6">
          <Skeleton className="lg:col-span-2 h-48" />
          <Skeleton className="h-48" />
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-6xl mx-auto p-6">
        <p className="text-destructive">{error}</p>
        <Link to="/accounts" className="text-sm text-muted-foreground underline mt-2 inline-block">
          ← Back to accounts
        </Link>
      </div>
    );
  }

  return (
    <div className="max-w-6xl mx-auto p-4 sm:p-6">
      {/* Header */}
      <div className="flex items-start justify-between gap-4 mb-6">
        <div>
          <Link to="/accounts" className="text-sm text-muted-foreground hover:underline mb-2 inline-block">
            ← My Accounts
          </Link>
          <div className="flex items-center gap-3 flex-wrap">
            <h1 className="text-2xl sm:text-3xl font-bold">{name}</h1>
            <AccountHealthBadge contacts={contacts} opps={opps} />
          </div>
          <p className="text-muted-foreground mt-1">
            {[industry, type].filter(Boolean).join(" · ")}
            {location ? ` · ${location}` : ""}
          </p>
        </div>
        <div className="text-right flex-shrink-0">
          {revenue && (
            <>
              <div className="text-xs text-muted-foreground">Annual Revenue</div>
              <div className="text-xl font-semibold">{revenue}</div>
            </>
          )}
        </div>
      </div>

      {/* Quick stats row */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <Card>
          <CardContent className="pt-4">
            <div className="text-xs text-muted-foreground">Open Deals</div>
            <div className="text-xl font-semibold">{openOpps.length}</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="text-xs text-muted-foreground">Closed Won</div>
            <div className="text-xl font-semibold">{closedWon.length}</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="text-xs text-muted-foreground">Contacts</div>
            <div className="text-xl font-semibold">{contacts.length}</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="text-xs text-muted-foreground">Employees</div>
            <div className="text-xl font-semibold">{employees || "—"}</div>
          </CardContent>
        </Card>
      </div>

      {/* Tabbed panels */}
      <Tabs defaultValue="overview">
        <TabsList className="mb-4">
          <TabsTrigger value="overview">Overview</TabsTrigger>
          <TabsTrigger value="deals">Deals ({opps.length})</TabsTrigger>
          <TabsTrigger value="contacts">Contacts ({contacts.length})</TabsTrigger>
          <TabsTrigger value="ai">AI Insights</TabsTrigger>
        </TabsList>

        {/* Overview */}
        <TabsContent value="overview">
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <Card>
              <CardHeader><CardTitle className="text-base">Account Details</CardTitle></CardHeader>
              <CardContent className="space-y-2 text-sm">
                {phone && <div><span className="text-muted-foreground">Phone: </span>{phone}</div>}
                {website && (
                  <div>
                    <span className="text-muted-foreground">Website: </span>
                    <a href={website} target="_blank" rel="noreferrer" className="underline">{website}</a>
                  </div>
                )}
                {location && <div><span className="text-muted-foreground">Location: </span>{location}</div>}
                {employees && <div><span className="text-muted-foreground">Employees: </span>{employees}</div>}
                {fieldValue(account?.Owner?.Name) && (
                  <div><span className="text-muted-foreground">Owner: </span>{fieldValue(account?.Owner?.Name)}</div>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader><CardTitle className="text-base">Description</CardTitle></CardHeader>
              <CardContent className="text-sm text-muted-foreground">
                {description || "No description provided."}
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        {/* Deals */}
        <TabsContent value="deals">
          <Card>
            <CardContent className="pt-4">
              {opps.length === 0 ? (
                <p className="text-sm text-muted-foreground py-6 text-center">No opportunities found for this account.</p>
              ) : (
                <div className="divide-y">
                  {opps.map((o: any, i: number) => {
                    const stage = fieldValue(o.StageName) ?? "";
                    const closeDate = o?.CloseDate?.displayValue ?? "";
                    const amount = o?.Amount?.displayValue ?? "";
                    return (
                      <div key={o?.Id ?? i} className="py-3 flex items-center justify-between gap-4">
                        <div>
                          <div className="font-medium">{fieldValue(o.Name) ?? "—"}</div>
                          <div className="text-sm text-muted-foreground">
                            Close: {closeDate || "—"}
                          </div>
                        </div>
                        <div className="flex items-center gap-3 text-right">
                          <div className="font-semibold">{amount || "—"}</div>
                          <StageBadge stage={stage} />
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* Contacts */}
        <TabsContent value="contacts">
          <Card>
            <CardContent className="pt-4">
              {contacts.length === 0 ? (
                <p className="text-sm text-muted-foreground py-6 text-center">No contacts found for this account.</p>
              ) : (
                <div className="divide-y">
                  {contacts.map((c: any, i: number) => (
                    <div key={c?.Id ?? i} className="py-3 flex items-center justify-between gap-4">
                      <div className="flex items-center gap-3">
                        <div className="w-9 h-9 rounded-full bg-primary/10 text-primary flex items-center justify-center text-sm font-semibold flex-shrink-0">
                          {(fieldValue(c.Name) ?? "?").charAt(0)}
                        </div>
                        <div>
                          <div className="font-medium">{fieldValue(c.Name) ?? "—"}</div>
                          <div className="text-sm text-muted-foreground">
                            {[fieldValue(c.Title), fieldValue(c.Department)].filter(Boolean).join(" · ") || "—"}
                          </div>
                        </div>
                      </div>
                      <div className="text-sm text-right text-muted-foreground">
                        {fieldValue(c.Email) && (
                          <a href={`mailto:${fieldValue(c.Email)}`} className="underline block">
                            {fieldValue(c.Email)}
                          </a>
                        )}
                        {fieldValue(c.Phone) && <div>{fieldValue(c.Phone)}</div>}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* AI Insights */}
        <TabsContent value="ai">
          <Card>
            <CardHeader><CardTitle className="text-base">Ask AI about this account</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              <div className="flex flex-wrap gap-2">
                {[
                  "Summarize this account",
                  "What are the risks?",
                  "Draft a follow-up email",
                  "What's the best next step?",
                ].map((prompt) => (
                  <button
                    key={prompt}
                    onClick={() => setAiPrompt(prompt)}
                    className="px-3 py-1.5 rounded-full border text-sm hover:bg-muted transition-colors"
                  >
                    {prompt}
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
                  className="flex-1 border rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary/50"
                />
                <Button onClick={handleAiPrompt} disabled={aiLoading || !aiPrompt.trim()}>
                  {aiLoading ? "Thinking..." : "Ask"}
                </Button>
              </div>

              {aiResponse && (
                <div className="rounded-md bg-muted p-4 text-sm whitespace-pre-wrap">
                  {aiResponse}
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
