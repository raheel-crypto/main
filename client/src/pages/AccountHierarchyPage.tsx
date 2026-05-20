import { useState } from "react";
import { cn } from "../lib/utils";
import {
  api,
  type AccountFamily,
  type AccountFamilyScan,
  type HierarchyProposal,
  type HierarchyApplyResult,
  type HierarchyNode,
} from "../lib/api";
import { HierarchyCanvas } from "../components/accounts/HierarchyCanvas";

export function AccountHierarchyPage() {
  const [scan, setScan] = useState<AccountFamilyScan | null>(null);
  const [isScanning, setIsScanning] = useState(false);
  const [selectedBrand, setSelectedBrand] = useState<string | null>(null);
  const [proposal, setProposal] = useState<HierarchyProposal | null>(null);
  const [isProposing, setIsProposing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [resolvedGapIds, setResolvedGapIds] = useState<Set<string>>(new Set());
  // After a gap is created, we substitute its synthetic id with the real account id everywhere.
  const [gapAccountIds, setGapAccountIds] = useState<Record<string, string>>({});
  const [creatingGap, setCreatingGap] = useState<string | null>(null);

  const [applying, setApplying] = useState(false);
  const [applyResult, setApplyResult] = useState<HierarchyApplyResult | null>(null);

  const runScan = async () => {
    setIsScanning(true);
    setError(null);
    setProposal(null);
    setSelectedBrand(null);
    setApplyResult(null);
    try {
      const result = await api.scanAccountFamilies();
      setScan(result);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setIsScanning(false);
    }
  };

  const propose = async (family: AccountFamily) => {
    setSelectedBrand(family.brandLabel);
    setIsProposing(true);
    setProposal(null);
    setApplyResult(null);
    setResolvedGapIds(new Set());
    setGapAccountIds({});
    setError(null);
    try {
      const p = await api.proposeAccountHierarchy(family.brandLabel, family);
      setProposal(p);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setIsProposing(false);
    }
  };

  const createGap = async (gapId: string) => {
    if (!proposal) return;
    const gap = proposal.gaps.find((g) => g.gapId === gapId);
    if (!gap) return;
    setCreatingGap(gapId);
    setError(null);
    try {
      const res = await api.createGapAccount({
        name: gap.proposedName,
        website: gap.suggestedWebsite,
        billingCountry: gap.suggestedBillingCountry,
        description: `Created via Account Hierarchy widget to fill gap for brand "${proposal.family.brandLabel}".`,
      });
      setGapAccountIds((prev) => ({ ...prev, [gapId]: res.id }));
      setResolvedGapIds((prev) => new Set([...prev, gapId]));
    } catch (e: any) {
      setError(e.message);
    } finally {
      setCreatingGap(null);
    }
  };

  // Resolve a proposed parent reference (may be "GAP:gap_1") into an actual Salesforce ID.
  const resolveProposedParentId = (proposed: string | null): string | null => {
    if (!proposed) return null;
    if (proposed.startsWith("GAP:")) {
      const gapId = proposed.slice(4);
      return gapAccountIds[gapId] || null;
    }
    return proposed;
  };

  const changesToApply: { accountId: string; newParentId: string; node: HierarchyNode }[] =
    proposal
      ? proposal.nodes
          .filter((n) => n.kind !== "gap" && n.accountId && n.isChange)
          .map((n) => ({
            node: n,
            accountId: n.accountId!,
            newParentId: resolveProposedParentId(n.proposedParentId) || "",
          }))
          .filter((c) => c.newParentId && c.newParentId !== c.accountId)
      : [];

  const blockedByGaps = proposal
    ? proposal.nodes.filter(
        (n) =>
          n.kind !== "gap" &&
          n.isChange &&
          n.proposedParentId?.startsWith("GAP:") &&
          !gapAccountIds[n.proposedParentId.slice(4)]
      ).length
    : 0;

  const apply = async () => {
    if (changesToApply.length === 0) return;
    setApplying(true);
    setError(null);
    try {
      const result = await api.applyAccountHierarchy(
        changesToApply.map((c) => ({ accountId: c.accountId, newParentId: c.newParentId }))
      );
      setApplyResult(result);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setApplying(false);
    }
  };

  // For the canvas: substitute any GAP-keyed parent refs with the real account id once created,
  // and drop the gap node itself in favor of the real account-shaped node.
  const canvasNodes: HierarchyNode[] = proposal
    ? proposal.nodes
        .map((n) => {
          if (n.kind === "gap" && gapAccountIds[n.id]) {
            return {
              ...n,
              id: gapAccountIds[n.id],
              accountId: gapAccountIds[n.id],
              kind: "ultimate-parent" as const,
            };
          }
          let parentNodeId = n.parentNodeId;
          if (parentNodeId && gapAccountIds[parentNodeId]) {
            parentNodeId = gapAccountIds[parentNodeId];
          }
          return { ...n, parentNodeId };
        })
    : [];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Account Hierarchy</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Find accounts that look like duplicates but are actually a family (e.g. country offices), then
          propose and apply a parent-child hierarchy with help from Claude.
        </p>
      </div>

      {!scan && !isScanning && (
        <div className="rounded-xl border border-border bg-card p-8 text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary/10">
            <svg className="h-8 w-8 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path d="M12 3v3m0 12v3m9-9h-3M6 12H3m12.7-6.7l-2.1 2.1M7.4 16.6l-2.1 2.1m13.4 0l-2.1-2.1M7.4 7.4L5.3 5.3" />
              <circle cx="12" cy="12" r="3.5" />
            </svg>
          </div>
          <h2 className="text-lg font-semibold text-foreground">Scan for account families</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            We&apos;ll group accounts that share a brand domain (e.g. all the Oaklins country offices) and
            highlight candidates for parenting.
          </p>
          <button
            onClick={runScan}
            className="mt-4 rounded-lg bg-primary px-6 py-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            Run Scan
          </button>
        </div>
      )}

      {isScanning && (
        <div className="rounded-xl border border-border bg-card p-8 text-center">
          <div className="mx-auto mb-4 h-8 w-8 animate-spin rounded-full border-3 border-primary border-t-transparent" />
          <h2 className="text-lg font-semibold text-foreground">Scanning accounts...</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Reading websites, normalizing domains, and clustering by brand.
          </p>
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-destructive/50 bg-destructive/5 p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {scan && !isScanning && (
        <div className="grid grid-cols-12 gap-4">
          {/* Families list */}
          <div className="col-span-4 space-y-3">
            <div className="rounded-lg border border-border bg-card p-3 text-xs text-muted-foreground">
              Scanned {scan.totalAccountsScanned} accounts. Found {scan.families.length} candidate{" "}
              {scan.families.length === 1 ? "family" : "families"}.
              {scan.linkedInField ? (
                <> LinkedIn field detected: <code className="text-foreground">{scan.linkedInField}</code>.</>
              ) : (
                <> No LinkedIn URL field detected on Account.</>
              )}
              <button
                onClick={runScan}
                className="ml-2 text-primary hover:underline"
              >
                Re-scan
              </button>
            </div>

            {scan.families.length === 0 && (
              <div className="rounded-lg border border-border bg-card p-4 text-sm text-muted-foreground">
                No account families found. Either everything is already parented, or no accounts share a
                domain.
              </div>
            )}

            {scan.families.map((family) => {
              const isSelected = family.brandLabel === selectedBrand;
              const orphanCount = family.accountCount - family.withParentCount;
              return (
                <button
                  key={family.brandLabel}
                  onClick={() => propose(family)}
                  className={cn(
                    "w-full rounded-lg border bg-card p-3 text-left transition-colors hover:border-primary/50",
                    isSelected ? "border-primary" : "border-border"
                  )}
                >
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-semibold text-foreground capitalize">
                      {family.brandLabel}
                    </span>
                    <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                      {family.accountCount} accounts
                    </span>
                  </div>
                  <div className="mt-1 text-xs text-muted-foreground line-clamp-1">
                    {family.representativeName}
                  </div>
                  <div className="mt-2 flex items-center gap-2 text-[11px] text-muted-foreground">
                    <span>{family.normalizedDomains.length} domain{family.normalizedDomains.length === 1 ? "" : "s"}</span>
                    <span>·</span>
                    <span>{family.billingCountries.length} countr{family.billingCountries.length === 1 ? "y" : "ies"}</span>
                    <span>·</span>
                    <span className={orphanCount > 0 ? "text-yellow-400" : "text-green-400"}>
                      {orphanCount} unparented
                    </span>
                  </div>
                </button>
              );
            })}
          </div>

          {/* Right pane: proposal & visualization */}
          <div className="col-span-8 space-y-4">
            {!selectedBrand && (
              <div className="rounded-xl border border-border bg-card p-8 text-center text-sm text-muted-foreground">
                Pick a family on the left to see the proposed hierarchy.
              </div>
            )}

            {isProposing && (
              <div className="rounded-xl border border-border bg-card p-8 text-center">
                <div className="mx-auto mb-4 h-8 w-8 animate-spin rounded-full border-3 border-primary border-t-transparent" />
                <div className="text-sm text-foreground">
                  Asking Claude to propose the hierarchy for {selectedBrand}...
                </div>
              </div>
            )}

            {proposal && !isProposing && (
              <>
                {proposal.summary && (
                  <div className="rounded-lg border border-primary/30 bg-primary/5 p-3 text-sm text-foreground">
                    <span className="font-medium text-primary">Proposal: </span>
                    {proposal.summary}
                  </div>
                )}

                {proposal.warnings.length > 0 && (
                  <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-3 text-sm text-yellow-300">
                    <div className="font-medium">Warnings</div>
                    <ul className="mt-1 list-disc pl-5 space-y-1">
                      {proposal.warnings.map((w, i) => (
                        <li key={i} className="text-xs text-yellow-200/90">{w}</li>
                      ))}
                    </ul>
                  </div>
                )}

                {proposal.gaps.length > 0 && (
                  <div className="rounded-lg border border-orange-500/30 bg-orange-500/5 p-3">
                    <div className="text-sm font-medium text-orange-300">
                      Gaps ({proposal.gaps.length})
                    </div>
                    <div className="mt-2 space-y-2">
                      {proposal.gaps.map((g) => {
                        const created = resolvedGapIds.has(g.gapId);
                        return (
                          <div
                            key={g.gapId}
                            className="flex items-start justify-between gap-3 rounded border border-orange-500/20 bg-background p-2"
                          >
                            <div className="flex-1">
                              <div className="text-sm font-medium text-foreground">
                                {g.proposedName}
                              </div>
                              <div className="text-xs text-muted-foreground">{g.reason}</div>
                              {(g.suggestedWebsite || g.suggestedBillingCountry) && (
                                <div className="mt-1 text-[11px] text-muted-foreground/80">
                                  {g.suggestedWebsite && <>web: {g.suggestedWebsite}</>}
                                  {g.suggestedWebsite && g.suggestedBillingCountry && " · "}
                                  {g.suggestedBillingCountry && <>country: {g.suggestedBillingCountry}</>}
                                </div>
                              )}
                            </div>
                            {created ? (
                              <span className="rounded bg-green-500/15 px-2 py-1 text-xs text-green-400">
                                Created
                              </span>
                            ) : (
                              <button
                                onClick={() => createGap(g.gapId)}
                                disabled={creatingGap === g.gapId}
                                className="rounded border border-orange-500/40 bg-orange-500/10 px-3 py-1 text-xs font-medium text-orange-300 hover:bg-orange-500/20 disabled:opacity-50"
                              >
                                {creatingGap === g.gapId ? "Creating..." : "Create Account"}
                              </button>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}

                <HierarchyCanvas nodes={canvasNodes} resolvedGapIds={resolvedGapIds} />

                <div className="rounded-lg border border-border bg-card p-3">
                  <div className="flex items-center justify-between">
                    <div className="text-sm font-medium text-foreground">
                      Proposed changes ({changesToApply.length})
                    </div>
                    <button
                      onClick={apply}
                      disabled={
                        applying ||
                        changesToApply.length === 0 ||
                        blockedByGaps > 0
                      }
                      className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                    >
                      {applying
                        ? "Applying..."
                        : blockedByGaps > 0
                        ? `Create ${blockedByGaps} gap${blockedByGaps === 1 ? "" : "s"} first`
                        : "Apply Hierarchy"}
                    </button>
                  </div>

                  {changesToApply.length === 0 && (
                    <div className="mt-2 text-xs text-muted-foreground">
                      No parent-id changes needed — the hierarchy is already in place.
                    </div>
                  )}

                  {changesToApply.length > 0 && (
                    <div className="mt-3 space-y-1.5">
                      {changesToApply.slice(0, 12).map((c) => {
                        const parentNode = proposal.nodes.find(
                          (n) => n.id === c.node.parentNodeId
                        );
                        return (
                          <div
                            key={c.accountId}
                            className="flex items-center justify-between rounded bg-background px-2 py-1.5 text-xs"
                          >
                            <span className="text-foreground">{c.node.name}</span>
                            <span className="text-muted-foreground">→</span>
                            <span className="text-foreground">{parentNode?.name || "(parent)"}</span>
                          </div>
                        );
                      })}
                      {changesToApply.length > 12 && (
                        <div className="text-xs text-muted-foreground">
                          ...and {changesToApply.length - 12} more
                        </div>
                      )}
                    </div>
                  )}
                </div>

                {applyResult && (
                  <div className="space-y-2">
                    {applyResult.applied.length > 0 && (
                      <div className="rounded-lg border border-green-500/30 bg-green-500/5 p-3 text-sm text-green-300">
                        Applied {applyResult.applied.length} parent-id update
                        {applyResult.applied.length === 1 ? "" : "s"}.
                      </div>
                    )}
                    {applyResult.failed.length > 0 && (
                      <div className="rounded-lg border border-destructive/40 bg-destructive/5 p-3 text-sm text-destructive">
                        <div className="font-medium">{applyResult.failed.length} update(s) failed</div>
                        <ul className="mt-1 list-disc pl-5">
                          {applyResult.failed.map((f) => (
                            <li key={f.accountId} className="text-xs">
                              {f.accountId}: {f.error}
                            </li>
                          ))}
                        </ul>
                      </div>
                    )}
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
