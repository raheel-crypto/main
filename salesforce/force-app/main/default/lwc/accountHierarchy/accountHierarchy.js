import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import scanFamilies from '@salesforce/apex/AccountHierarchyController.scanFamilies';
import listDedupeScans from '@salesforce/apex/AccountHierarchyController.listDedupeScans';
import scanFromDedupeGroups from '@salesforce/apex/AccountHierarchyController.scanFromDedupeGroups';
import proposeHierarchy from '@salesforce/apex/AccountHierarchyController.proposeHierarchy';
import applyChanges from '@salesforce/apex/AccountHierarchyController.applyChanges';
import createGapAccount from '@salesforce/apex/AccountHierarchyController.createGapAccount';

const KIND_LABELS = {
    'ultimate-parent': 'Ultimate Parent',
    'regional-parent': 'Regional Parent',
    'child': 'Child Account',
    'gap': 'Gap — Needs Creating'
};

// Per-depth color palette — each level of the hierarchy gets its own hue so
// the tree is readable at a glance even at 5+ levels.
const DEPTH_PALETTE = [
    { stroke: '#0176d3', headBg: '#0176d318', accent: '#0176d3' }, // L0 blue
    { stroke: '#04844b', headBg: '#04844b18', accent: '#04844b' }, // L1 green
    { stroke: '#7f4dab', headBg: '#7f4dab18', accent: '#7f4dab' }, // L2 purple
    { stroke: '#fe9339', headBg: '#fe933918', accent: '#fe9339' }, // L3 orange
    { stroke: '#c93396', headBg: '#c9339618', accent: '#c93396' }, // L4 magenta
    { stroke: '#0d9488', headBg: '#0d948818', accent: '#0d9488' }  // L5 teal
];
const GAP_STYLE = { stroke: '#ea7600', headBg: '#ea760018', accent: '#ea7600' };

const NODE_W = 240;
const NODE_H = 96;
const H_GAP = 36;
const V_GAP = 64;
const MAX_NAME_CHARS = 28;
const MAX_META_CHARS = 30;

// Path for a rect with only the top corners rounded — used for the colored
// header band so it sits flush against the body of the node.
function topRoundedRectPath(x, y, w, h, r) {
    return `M ${x + r} ${y} `
        + `H ${x + w - r} `
        + `A ${r} ${r} 0 0 1 ${x + w} ${y + r} `
        + `V ${y + h} `
        + `H ${x} `
        + `V ${y + r} `
        + `A ${r} ${r} 0 0 1 ${x + r} ${y} Z`;
}

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

    // Source selection: 'dedupe' (use Dedupe_Group__c records) or 'heuristic' (live brand-clustering).
    @track sourceMode = 'dedupe';
    @track dedupeScans = [];
    @track selectedDedupeScanId = null;
    @track loadingDedupeScans = false;

    connectedCallback() {
        this.loadDedupeScans();
    }

    async loadDedupeScans() {
        this.loadingDedupeScans = true;
        try {
            this.dedupeScans = await listDedupeScans();
            // Auto-select the most recent completed scan that has open groups.
            const recent = this.dedupeScans.find((s) => s.status === 'Completed' && s.openGroupCount > 0);
            if (recent) this.selectedDedupeScanId = recent.id;
        } catch (e) {
            // Schema may not be present — silently fall through to heuristic-only mode.
            this.dedupeScans = [];
        } finally {
            this.loadingDedupeScans = false;
        }
    }

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
            const tileKey = f.dedupeGroupId || f.brandLabel;
            const selectedKey = this.selectedFamilyKey;
            return {
                ...f,
                tileKey,
                tileClass: tileKey === selectedKey
                    ? 'family-tile family-tile--selected'
                    : 'family-tile',
                orphanCount: orphans,
                orphanClass: orphans > 0 ? 'orphan-count orphan-count--warn' : 'orphan-count orphan-count--ok',
                domainNoun: f.normalizedDomains.length === 1 ? 'domain' : 'domains',
                countryNoun: f.billingCountries.length === 1 ? 'country' : 'countries',
                hasMatchSignals: !!f.matchSignals,
                matchSignals: f.matchSignals || ''
            };
        });
    }

    // We key tiles by Dedupe Group ID when available (multiple groups can share
    // the same derived brandLabel, e.g. "ey"), and fall back to brandLabel.
    @track selectedFamilyKey = null;

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
            node.depth = depth;
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
            const palette = n.kind === 'gap'
                ? GAP_STYLE
                : DEPTH_PALETTE[Math.min(n.depth || 0, DEPTH_PALETTE.length - 1)];
            const isUltimate = n.kind === 'ultimate-parent';
            const cx = n.x + offsetX;
            const cy = n.y + offsetY;
            const HEADER_H = 28;
            const tooltipParts = [n.name];
            if (n.billingCountry) tooltipParts.push(n.billingCountry);
            if (n.website) tooltipParts.push(n.website);

            return {
                key: n.id,
                // outer rect
                x: cx - NODE_W / 2,
                y: cy,
                width: NODE_W,
                height: NODE_H,
                stroke: palette.stroke,
                strokeWidth: isUltimate ? 2.5 : 1.5,
                strokeDash: (n.kind === 'gap' && !this.resolvedGapIds[n.id]) ? '6 4' : '',
                // header band — only the top corners rounded so it sits flush.
                headerPath: topRoundedRectPath(cx - NODE_W / 2, cy, NODE_W, HEADER_H, 8),
                headerFill: palette.headBg,
                // left accent stripe — short of the bottom to clear the rounded corner.
                accentX: cx - NODE_W / 2,
                accentY: cy + HEADER_H,
                accentW: 4,
                accentH: NODE_H - HEADER_H - 8,
                accentFill: palette.accent,
                // text positions (centered)
                cx,
                headerTextY: cy + 18,
                nameY: cy + 50,
                metaY: cy + 68,
                webY: cy + 84,
                kindLabel: KIND_LABELS[n.kind] || `Level ${n.depth || 0}`,
                kindColor: palette.accent,
                nameWeight: isUltimate ? 700 : 600,
                name: this.truncate(n.name, MAX_NAME_CHARS),
                metaLine: this.truncate(n.billingCountry || '', MAX_META_CHARS),
                website: this.truncate(n.website, MAX_META_CHARS),
                // change badge — anchored to top-right of header
                showChange: n.isChange,
                changeX: cx + NODE_W / 2 - 56,
                changeY: cy + 6,
                // full text for browser tooltip on hover
                tooltip: tooltipParts.join(' — ')
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
            // Edge color follows the child's level color, so the eye traces the hierarchy by hue.
            const childPalette = n.kind === 'gap'
                ? GAP_STYLE
                : DEPTH_PALETTE[Math.min(n.depth || 0, DEPTH_PALETTE.length - 1)];
            const color = childPalette.accent;
            const arrowPoints = `${x2 - 5},${y2 - 8} ${x2 + 5},${y2 - 8} ${x2},${y2}`;
            svgEdges.push({
                key: `${parent.id}-${n.id}`,
                d: path,
                stroke: color,
                dasharray: n.isChange ? '6 4' : '',
                width: n.isChange ? 2.5 : 1.5,
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
        return this.hasFamilies && !this.selectedFamilyKey && !this.isProposing;
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
        this.selectedFamilyKey = null;
        this.applyResult = null;
        try {
            if (this.sourceMode === 'dedupe') {
                this.scanResult = await scanFromDedupeGroups({ scanId: this.selectedDedupeScanId });
            } else {
                this.scanResult = await scanFamilies();
            }
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isScanning = false;
        }
    }

    handleSourceChange(event) {
        this.sourceMode = event.detail.value;
        this.scanResult = null;
        this.proposal = null;
        this.selectedBrand = null;
        this.selectedFamilyKey = null;
        this.applyResult = null;
    }

    handleDedupeScanChange(event) {
        this.selectedDedupeScanId = event.detail.value;
        this.scanResult = null;
        this.proposal = null;
        this.selectedBrand = null;
        this.selectedFamilyKey = null;
    }

    get sourceOptions() {
        return [
            { label: 'Dedupe Groups (recommended)', value: 'dedupe' },
            { label: 'Live brand-clustering scan', value: 'heuristic' }
        ];
    }

    get dedupeScanOptions() {
        return this.dedupeScans.map((s) => {
            const date = s.createdDate ? new Date(s.createdDate).toLocaleString() : '';
            return {
                label: `${s.name} — ${s.status}, ${s.openGroupCount} open groups (${date})`,
                value: s.id
            };
        });
    }

    get showDedupeScanPicker() {
        return this.sourceMode === 'dedupe' && this.dedupeScans.length > 0;
    }

    get showNoDedupeScansMessage() {
        return this.sourceMode === 'dedupe' && !this.loadingDedupeScans && this.dedupeScans.length === 0;
    }

    async handleSelectFamily(event) {
        const key = event.currentTarget.dataset.key;
        const family = this.scanResult.families.find(
            (f) => (f.dedupeGroupId || f.brandLabel) === key
        );
        if (!family) return;

        this.selectedFamilyKey = key;
        this.selectedBrand = family.brandLabel;
        this.proposal = null;
        this.applyResult = null;
        this.resolvedGapIds = {};
        this.isProposing = true;
        this.errorMessage = null;
        try {
            // JSON-stringify to bypass LWC's reactive-proxy marshalling, which can
            // drop nested list fields when Apex deserializes them automatically.
            this.proposal = await proposeHierarchy({ familyJson: JSON.stringify(family) });
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
            const newId = await createGapAccount({ inputJson: JSON.stringify(input) });
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
            this.applyResult = await applyChanges({ changesJson: JSON.stringify(changes) });
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
