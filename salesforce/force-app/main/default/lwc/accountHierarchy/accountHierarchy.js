import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import scanFamilies from '@salesforce/apex/AccountHierarchyController.scanFamilies';
import proposeHierarchy from '@salesforce/apex/AccountHierarchyController.proposeHierarchy';
import applyChanges from '@salesforce/apex/AccountHierarchyController.applyChanges';
import createGapAccount from '@salesforce/apex/AccountHierarchyController.createGapAccount';

const KIND_COLORS = {
    'ultimate-parent': '#04844b',
    'regional-parent': '#0070d2',
    'child': '#706e6b',
    'gap': '#ea7600'
};

const KIND_LABELS = {
    'ultimate-parent': 'Ultimate Parent',
    'regional-parent': 'Regional Parent',
    'child': 'Child Account',
    'gap': 'Gap — Needs Creating'
};

const NODE_W = 220;
const NODE_H = 88;
const H_GAP = 32;
const V_GAP = 60;

export default class AccountHierarchy extends LightningElement {
    @track scanResult;
    @track selectedBrand;
    @track proposal;

    @track resolvedGapIds = {}; // gapId -> created Salesforce Id

    @track isScanning = false;
    @track isProposing = false;
    @track isApplying = false;
    @track creatingGapId = null;
    @track applyResult;
    @track errorMessage = null;

    // ---------- Computed ----------

    get hasScanned() {
        return !!this.scanResult;
    }

    get hasFamilies() {
        return this.scanResult && this.scanResult.families && this.scanResult.families.length > 0;
    }

    get scanSummary() {
        if (!this.scanResult) return '';
        const count = this.scanResult.families.length;
        const word = count === 1 ? 'family' : 'families';
        const linkedinNote = this.scanResult.linkedInField
            ? `LinkedIn field detected: ${this.scanResult.linkedInField}.`
            : 'No LinkedIn URL field detected on Account.';
        return `Scanned ${this.scanResult.totalAccountsScanned} accounts. Found ${count} candidate ${word}. ${linkedinNote}`;
    }

    get familyTiles() {
        if (!this.scanResult) return [];
        return this.scanResult.families.map((f) => {
            const orphans = f.accountCount - f.withParentCount;
            return {
                ...f,
                tileClass: f.brandLabel === this.selectedBrand
                    ? 'family-tile family-tile--selected'
                    : 'family-tile',
                orphanCount: orphans,
                orphanClass: orphans > 0 ? 'orphan-count orphan-count--warn' : 'orphan-count orphan-count--ok',
                domainNoun: f.normalizedDomains.length === 1 ? 'domain' : 'domains',
                countryNoun: f.billingCountries.length === 1 ? 'country' : 'countries'
            };
        });
    }

    // The list of changes the user is about to apply, resolving GAP refs to real Ids.
    get pendingChanges() {
        if (!this.proposal) return [];
        const byId = {};
        this.proposal.nodes.forEach((n) => { byId[n.id] = n; });
        const list = [];
        this.proposal.nodes.forEach((n) => {
            if (n.kind === 'gap' || !n.accountId || !n.isChange) return;
            const resolved = this.resolveParentRef(n.proposedParentId);
            if (!resolved || resolved === n.accountId) return;
            list.push({
                accountId: n.accountId,
                newParentId: resolved,
                childName: n.name,
                parentName: (byId[n.parentNodeId] && byId[n.parentNodeId].name) || '(parent)'
            });
        });
        return list;
    }

    get pendingChangeCount() {
        return this.pendingChanges.length;
    }

    get pendingChangesPreview() {
        return this.pendingChanges.slice(0, 12);
    }

    get pendingChangesOverflow() {
        return Math.max(0, this.pendingChanges.length - 12);
    }

    get hasOverflow() {
        return this.pendingChangesOverflow > 0;
    }

    get blockedGapCount() {
        if (!this.proposal) return 0;
        let n = 0;
        this.proposal.nodes.forEach((node) => {
            if (node.kind === 'gap') return;
            if (!node.isChange) return;
            if (node.proposedParentId && node.proposedParentId.startsWith('GAP:')) {
                const gapId = node.proposedParentId.substring(4);
                if (!this.resolvedGapIds[gapId]) n++;
            }
        });
        return n;
    }

    get applyButtonLabel() {
        if (this.isApplying) return 'Applying...';
        if (this.blockedGapCount > 0) {
            const noun = this.blockedGapCount === 1 ? 'gap' : 'gaps';
            return `Create ${this.blockedGapCount} ${noun} first`;
        }
        return 'Apply Hierarchy';
    }

    get applyDisabled() {
        return this.isApplying
            || this.pendingChangeCount === 0
            || this.blockedGapCount > 0;
    }

    get hasSummary() {
        return this.proposal && !!this.proposal.summary;
    }

    get hasWarnings() {
        return this.proposal && this.proposal.warnings && this.proposal.warnings.length > 0;
    }

    get warningRows() {
        return (this.proposal.warnings || []).map((w, i) => ({ key: i, text: w }));
    }

    get gapCards() {
        if (!this.proposal) return [];
        return this.proposal.gaps.map((g) => {
            const created = !!this.resolvedGapIds[g.gapId];
            const lines = [];
            if (g.suggestedWebsite) lines.push(`web: ${g.suggestedWebsite}`);
            if (g.suggestedBillingCountry) lines.push(`country: ${g.suggestedBillingCountry}`);
            return {
                ...g,
                created,
                detailLine: lines.join(' · '),
                hasDetail: lines.length > 0,
                buttonLabel: this.creatingGapId === g.gapId ? 'Creating...' : 'Create Account',
                buttonDisabled: this.creatingGapId === g.gapId
            };
        });
    }

    get hasGaps() {
        return this.proposal && this.proposal.gaps && this.proposal.gaps.length > 0;
    }

    get hasAppliedSomething() {
        return this.applyResult && this.applyResult.applied && this.applyResult.applied.length > 0;
    }

    get appliedCountText() {
        const n = this.applyResult.applied.length;
        return `Applied ${n} parent-id update${n === 1 ? '' : 's'}.`;
    }

    get hasApplyFailures() {
        return this.applyResult && this.applyResult.failed && this.applyResult.failed.length > 0;
    }

    get applyFailureRows() {
        return this.applyResult.failed.map((f) => ({ key: f.accountId, ...f }));
    }

    // ---------- SVG layout ----------

    resolveParentRef(ref) {
        if (!ref) return null;
        if (ref.startsWith('GAP:')) {
            const gapId = ref.substring(4);
            return this.resolvedGapIds[gapId] || null;
        }
        return ref;
    }

    // Tree layout (Reingold-Tilford-ish): compute subtree widths, then x-position by leaf order.
    get svgTree() {
        if (!this.proposal) return null;

        // Substitute gap nodes that have been resolved into real account nodes.
        const nodes = this.proposal.nodes.map((n) => {
            if (n.kind === 'gap' && this.resolvedGapIds[n.id]) {
                return { ...n, id: this.resolvedGapIds[n.id], accountId: this.resolvedGapIds[n.id], kind: 'ultimate-parent' };
            }
            let parentNodeId = n.parentNodeId;
            if (parentNodeId && this.resolvedGapIds[parentNodeId]) {
                parentNodeId = this.resolvedGapIds[parentNodeId];
            }
            return { ...n, parentNodeId };
        });

        const byId = {};
        nodes.forEach((n) => { byId[n.id] = { ...n, children: [] }; });
        const roots = [];
        nodes.forEach((n) => {
            if (n.parentNodeId && byId[n.parentNodeId]) {
                byId[n.parentNodeId].children.push(byId[n.id]);
            } else {
                roots.push(byId[n.id]);
            }
        });

        // Cycle guard: if no roots (every node is parented), promote the first node.
        if (roots.length === 0 && nodes.length > 0) {
            roots.push(byId[nodes[0].id]);
        }

        // First pass — compute layout width of each subtree (in "slots"). Visited set
        // protects against cycles in the parent graph.
        const measure = (node, seen) => {
            if (seen.has(node.id)) { node.width = 1; return 1; }
            seen.add(node.id);
            if (node.children.length === 0) { node.width = 1; return 1; }
            let total = 0;
            for (const c of node.children) total += measure(c, seen);
            node.width = Math.max(1, total);
            return node.width;
        };
        roots.forEach((r) => measure(r, new Set()));

        // Second pass — assign x (centered within own slot range), y by depth.
        const positioned = [];
        const place = (node, depth, slotStart, seen) => {
            if (seen.has(node.id)) return;
            seen.add(node.id);
            const slotEnd = slotStart + node.width;
            const slotCenter = (slotStart + slotEnd) / 2;
            node.x = slotCenter * (NODE_W + H_GAP);
            node.y = depth * (NODE_H + V_GAP);
            positioned.push(node);
            let cursor = slotStart;
            for (const c of node.children) {
                place(c, depth + 1, cursor, seen);
                cursor += c.width;
            }
        };
        let rootCursor = 0;
        const placedSeen = new Set();
        roots.forEach((r) => {
            place(r, 0, rootCursor, placedSeen);
            rootCursor += r.width;
        });

        // Compute viewBox to fit everything.
        let minX = Infinity, maxX = -Infinity, maxY = -Infinity;
        positioned.forEach((n) => {
            minX = Math.min(minX, n.x - NODE_W / 2);
            maxX = Math.max(maxX, n.x + NODE_W / 2);
            maxY = Math.max(maxY, n.y + NODE_H);
        });
        if (!isFinite(minX)) { minX = 0; maxX = NODE_W; maxY = NODE_H; }

        const PAD = 24;
        const width  = (maxX - minX) + PAD * 2;
        const height = maxY + PAD * 2;
        const offsetX = PAD - minX;
        const offsetY = PAD;

        // Build SVG render data.
        const svgNodes = positioned.map((n) => {
            const color = KIND_COLORS[n.kind] || '#706e6b';
            const cx = n.x + offsetX;
            const cy = n.y + offsetY;
            return {
                key: n.id,
                x: cx - NODE_W / 2,
                y: cy,
                cx,
                cy,
                headerY: cy + 22,
                nameY: cy + 44,
                metaY: cy + 60,
                webY: cy + 76,
                width: NODE_W,
                height: NODE_H,
                color,
                fill: color + '15',
                kindLabel: KIND_LABELS[n.kind] || '',
                showChange: n.isChange,
                changeX: cx + NODE_W / 2 - 56,
                changeY: cy + 14,
                name: n.name,
                metaLine: n.billingCountry || '',
                website: this.truncate(n.website, 32),
                strokeDash: (n.kind === 'gap' && !this.resolvedGapIds[n.id]) ? '6 4' : ''
            };
        });

        const svgEdges = [];
        positioned.forEach((n) => {
            if (!n.parentNodeId) return;
            const parent = byId[n.parentNodeId];
            if (!parent) return;
            const x1 = parent.x + offsetX;
            const y1 = parent.y + offsetY + NODE_H;
            const x2 = n.x + offsetX;
            const y2 = n.y + offsetY;
            const midY = (y1 + y2) / 2;
            const path = `M ${x1} ${y1} C ${x1} ${midY}, ${x2} ${midY}, ${x2} ${y2}`;
            const color = n.isChange ? '#04844b' : '#706e6b';
            // Inline arrowhead triangle — avoids SVG <marker> camelCase attrs that LWC rejects.
            const arrowPoints = `${x2 - 5},${y2 - 8} ${x2 + 5},${y2 - 8} ${x2},${y2}`;
            svgEdges.push({
                key: `${parent.id}-${n.id}`,
                d: path,
                stroke: color,
                dasharray: n.isChange ? '6 4' : '',
                width: n.isChange ? 2 : 1.5,
                arrowPoints,
                arrowFill: color
            });
        });

        return {
            width,
            height,
            viewBox: `0 0 ${width} ${height}`,
            nodes: svgNodes,
            edges: svgEdges
        };
    }

    get hasTree() {
        return !!this.svgTree;
    }

    // Conditional render helpers — LWC `lwc:else` must sit on a sibling template,
    // so flatten the branching into named flags.
    get showRunPrompt() {
        return !this.hasScanned && !this.isScanning;
    }

    get showNoFamiliesMessage() {
        return this.hasScanned && !this.hasFamilies && !this.isScanning;
    }

    get showPickFamily() {
        return this.hasFamilies && !this.selectedBrand && !this.isProposing;
    }

    truncate(s, n) {
        if (!s) return '';
        return s.length > n ? s.substring(0, n - 1) + '…' : s;
    }

    // ---------- Event handlers ----------

    async handleRunScan() {
        this.isScanning = true;
        this.errorMessage = null;
        this.proposal = null;
        this.selectedBrand = null;
        this.applyResult = null;
        try {
            this.scanResult = await scanFamilies();
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isScanning = false;
        }
    }

    async handleSelectFamily(event) {
        const brand = event.currentTarget.dataset.brand;
        const family = this.scanResult.families.find((f) => f.brandLabel === brand);
        if (!family) return;

        this.selectedBrand = brand;
        this.proposal = null;
        this.applyResult = null;
        this.resolvedGapIds = {};
        this.isProposing = true;
        this.errorMessage = null;
        try {
            this.proposal = await proposeHierarchy({ family });
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isProposing = false;
        }
    }

    async handleCreateGap(event) {
        const gapId = event.currentTarget.dataset.gapid;
        const gap = this.proposal.gaps.find((g) => g.gapId === gapId);
        if (!gap) return;

        this.creatingGapId = gapId;
        this.errorMessage = null;
        try {
            const input = {
                gapName: gap.proposedName,
                website: gap.suggestedWebsite,
                billingCountry: gap.suggestedBillingCountry,
                description: `Created via Account Hierarchy LWC for brand "${this.proposal.family.brandLabel}".`
            };
            const newId = await createGapAccount({ input });
            this.resolvedGapIds = { ...this.resolvedGapIds, [gapId]: newId };
            this.toast('Account created', `${gap.proposedName} was created.`, 'success');
        } catch (e) {
            this.handleError(e);
        } finally {
            this.creatingGapId = null;
        }
    }

    async handleApply() {
        const changes = this.pendingChanges.map((c) => ({
            accountId: c.accountId,
            newParentId: c.newParentId
        }));
        if (changes.length === 0) return;

        this.isApplying = true;
        this.errorMessage = null;
        try {
            this.applyResult = await applyChanges({ changes });
            const appliedCount = this.applyResult.applied.length;
            const failedCount = this.applyResult.failed.length;
            if (failedCount === 0) {
                this.toast('Hierarchy applied', `Updated ${appliedCount} account(s).`, 'success');
            } else {
                this.toast(
                    'Applied with errors',
                    `${appliedCount} succeeded, ${failedCount} failed.`,
                    failedCount === changes.length ? 'error' : 'warning'
                );
            }
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isApplying = false;
        }
    }

    handleError(e) {
        const msg = (e && (e.body && e.body.message)) || (e && e.message) || 'Unexpected error';
        this.errorMessage = msg;
        this.toast('Error', msg, 'error');
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
