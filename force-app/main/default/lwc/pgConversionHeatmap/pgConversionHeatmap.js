import { LightningElement, wire } from 'lwc';
import getConversionHeatmap from '@salesforce/apex/PGInsightsController.getConversionHeatmap';
import getHeatmapCellOpps   from '@salesforce/apex/PGInsightsController.getHeatmapCellOpps';

const TRANSITION_LABELS = {
    1: 'Demo → Discovery',
    2: 'Discovery → POV',
    3: 'POV → Proposal',
    4: 'Proposal → Contracting',
    5: 'Contracting → Closed Won'
};

export default class PgConversionHeatmap extends LightningElement {
    grouping = 'AE';        // 'AE' | 'Pod'
    combineIB = false;
    groupByManager = true;  // applies only in AE mode
    metric = 'count';       // 'count' | 'amount'
    rawRows;
    error;

    // Drill-down modal state
    drillOpen = false;
    drillTitle = '';
    drillRows = [];
    drillLoading = false;

    @wire(getConversionHeatmap, { groupBy: '$grouping', combineIB: '$combineIB' })
    wired({ data, error }) {
        if (data) this.rawRows = data;
        if (error) this.error = error;
    }

    get aeToggleClass()  { return 'pg-mini-toggle__btn' + (this.grouping === 'AE'  ? ' pg-mini-toggle__btn--active' : ''); }
    get podToggleClass() { return 'pg-mini-toggle__btn' + (this.grouping === 'Pod' ? ' pg-mini-toggle__btn--active' : ''); }
    get countToggleClass()  { return 'pg-mini-toggle__btn' + (this.metric === 'count'  ? ' pg-mini-toggle__btn--active' : ''); }
    get amountToggleClass() { return 'pg-mini-toggle__btn' + (this.metric === 'amount' ? ' pg-mini-toggle__btn--active' : ''); }
    get isPodMode()      { return this.grouping === 'Pod'; }
    get isAmount()       { return this.metric === 'amount'; }
    get showGroupByManager() { return this.grouping === 'AE'; }
    get isGrouped()      { return this.showGroupByManager && this.groupByManager; }

    handleSelectAE()  { this.grouping = 'AE';  }
    handleSelectPod() { this.grouping = 'Pod'; }
    handleSelectCount()  { this.metric = 'count';  }
    handleSelectAmount() { this.metric = 'amount'; }
    handleToggleCombineIB(event) { this.combineIB = event.target.checked; }
    handleToggleGroupByManager(event) { this.groupByManager = event.target.checked; }

    get rows() {
        if (!this.rawRows) return [];
        const isAmt = this.isAmount;
        const pickD2D = r => isAmt ? r.demoToDiscoAmount           : r.demoToDisco;
        const pickD2P = r => isAmt ? r.discoToPovAmount            : r.discoToPov;
        const pickP2P = r => isAmt ? r.povToProposalAmount         : r.povToProposal;
        const pickPr2C= r => isAmt ? r.proposalToContractingAmount : r.proposalToContracting;
        const pickC2W = r => isAmt ? r.contractingToWonAmount      : r.contractingToWon;
        return this.rawRows.map(r => {
            const d2d = pickD2D(r);
            const d2p = pickD2P(r);
            const p2p = pickP2P(r);
            const pr2c = pickPr2C(r);
            const c2w = pickC2W(r);
            return {
                ...r,
                groupKey: this.isPodMode ? r.ownerName : r.ownerId,
                demoToDiscoFmt:           this.fmt(d2d),
                discoToPovFmt:            this.fmt(d2p),
                povToProposalFmt:         this.fmt(p2p),
                proposalToContractingFmt: this.fmt(pr2c),
                contractingToWonFmt:      this.fmt(c2w),
                demoToDiscoClass:           this.cellClass(d2d),
                discoToPovClass:            this.cellClass(d2p),
                povToProposalClass:         this.cellClass(p2p),
                proposalToContractingClass: this.cellClass(pr2c),
                contractingToWonClass:      this.cellClass(c2w)
            };
        });
    }

    get hasRows() { return this.rows.length > 0; }

    // When grouped, bucket AE rows by manager. The manager header row has
    // no rate cells — percentages can't be averaged without underlying
    // numerators / denominators, which the Apex doesn't currently expose.
    // It's purely a visual section break to keep an AE's report card next
    // to their teammates'.
    get rowGroups() {
        if (!this.isGrouped) return null;
        const rows = this.rows;
        if (!rows.length) return [];
        const buckets = new Map();
        for (const r of rows) {
            const key = r.managerName || '— No Manager —';
            let b = buckets.get(key);
            if (!b) {
                b = { key, managerName: key, rows: [] };
                buckets.set(key, b);
            }
            b.rows.push(r);
        }
        return Array.from(buckets.values())
            .sort((a, b) => a.managerName.localeCompare(b.managerName))
            .map(g => ({
                ...g,
                rowCount: g.rows.length,
                rows: g.rows.map((r, idx) => ({ ...r, isFirstInGroup: idx === 0 }))
            }));
    }

    fmt(val) {
        if (val == null) return 'N/A';
        const n = Number(val);
        if (!Number.isFinite(n)) return 'N/A';
        return Math.round(n) + '%';
    }

    cellClass(val) {
        if (val == null) return 'pg-cell pg-cell--empty';
        if (val >= 75) return 'pg-cell pg-cell--green';
        if (val >= 50) return 'pg-cell pg-cell--lime';
        if (val >= 30) return 'pg-cell pg-cell--yellow';
        return 'pg-cell pg-cell--red';
    }

    handleCellClick(event) {
        const fromRank = parseInt(event.currentTarget.dataset.fromRank, 10);
        const groupKey = event.currentTarget.dataset.groupKey;
        const ownerName = event.currentTarget.dataset.ownerName;
        if (!fromRank || !groupKey) return;

        this.drillTitle = `${ownerName} · ${TRANSITION_LABELS[fromRank]}`;
        this.drillOpen = true;
        this.drillLoading = true;
        this.drillRows = [];

        getHeatmapCellOpps({
            groupKey,
            fromRank,
            groupBy: this.grouping,
            combineIB: this.combineIB
        })
            .then(data => {
                this.drillRows = (data || []).map(o => ({
                    ...o,
                    amountFmt: this.fmtCurrency(o.amount),
                    closeDateFmt: this.fmtDate(o.closeDate),
                    rowClass: this.rowClassForCategory(o.category),
                    statusLabel: this.statusLabelFor(o)
                }));
                this.drillLoading = false;
            })
            .catch(() => { this.drillLoading = false; });
    }

    statusLabelFor(o) {
        switch (o.category) {
            case 'CLOSED_WON':
                return 'Closed Won';
            case 'OPEN_LATER_STAGE':
                return `Open · ${o.stageName}`;
            case 'CLOSED_LOST_PROGRESSED':
                return `Closed Lost (peaked at ${o.highestStageReached || '—'})`;
            case 'CLOSED_LOST_AT_SOURCE':
                return 'Closed Lost (didn’t advance)';
            case 'IN_FLIGHT_AT_SOURCE':
                return `Open · ${o.stageName} (not counted)`;
            default:
                return o.stageName || '';
        }
    }

    rowClassForCategory(cat) {
        switch (cat) {
            case 'CLOSED_WON':             return 'pg-drill__row pg-drill__row--won';
            case 'OPEN_LATER_STAGE':       return 'pg-drill__row pg-drill__row--open';
            case 'CLOSED_LOST_PROGRESSED': return 'pg-drill__row pg-drill__row--lost-progressed';
            case 'CLOSED_LOST_AT_SOURCE':  return 'pg-drill__row pg-drill__row--lost-source';
            case 'IN_FLIGHT_AT_SOURCE':    return 'pg-drill__row pg-drill__row--in-flight';
            default:                       return 'pg-drill__row';
        }
    }

    get drillSummary() {
        if (!this.drillRows || !this.drillRows.length) return null;
        const counts = {
            CLOSED_WON: 0,
            OPEN_LATER_STAGE: 0,
            CLOSED_LOST_PROGRESSED: 0,
            CLOSED_LOST_AT_SOURCE: 0,
            IN_FLIGHT_AT_SOURCE: 0
        };
        for (const r of this.drillRows) {
            if (counts[r.category] != null) counts[r.category]++;
        }
        const advanced = counts.CLOSED_WON + counts.OPEN_LATER_STAGE + counts.CLOSED_LOST_PROGRESSED;
        const settled  = advanced + counts.CLOSED_LOST_AT_SOURCE;
        const pct = settled === 0 ? null : Math.round((advanced / settled) * 100);
        return {
            advanced,
            settled,
            inFlight: counts.IN_FLIGHT_AT_SOURCE,
            pct: pct == null ? 'N/A' : `${pct}%`,
            won:           counts.CLOSED_WON,
            openLater:     counts.OPEN_LATER_STAGE,
            lostProgressed: counts.CLOSED_LOST_PROGRESSED,
            lostSource:    counts.CLOSED_LOST_AT_SOURCE
        };
    }

    closeDrill() { this.drillOpen = false; }
    preventBackdropClose(event) { event.stopPropagation(); }

    fmtCurrency(n) {
        if (n == null) return '—';
        const v = Number(n);
        if (!Number.isFinite(v)) return '—';
        if (v >= 1_000_000) return `$${(v / 1_000_000).toFixed(2)}M`;
        if (v >= 1_000)     return `$${(v / 1_000).toFixed(0)}K`;
        return `$${Math.round(v)}`;
    }

    fmtDate(d) {
        if (!d) return '—';
        return d;
    }
}
