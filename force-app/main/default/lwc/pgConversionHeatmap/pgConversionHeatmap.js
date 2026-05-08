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
    get isPodMode()      { return this.grouping === 'Pod'; }

    handleSelectAE()  { this.grouping = 'AE';  }
    handleSelectPod() { this.grouping = 'Pod'; }
    handleToggleCombineIB(event) { this.combineIB = event.target.checked; }

    get rows() {
        if (!this.rawRows) return [];
        return this.rawRows.map(r => ({
            ...r,
            // Stable group key for drilldown: ownerId in AE mode, ownerName (pod label) in Pod mode.
            groupKey: this.isPodMode ? r.ownerName : r.ownerId,
            demoToDiscoFmt:           this.fmt(r.demoToDisco),
            discoToPovFmt:            this.fmt(r.discoToPov),
            povToProposalFmt:         this.fmt(r.povToProposal),
            proposalToContractingFmt: this.fmt(r.proposalToContracting),
            contractingToWonFmt:      this.fmt(r.contractingToWon),
            demoToDiscoClass:           this.cellClass(r.demoToDisco),
            discoToPovClass:            this.cellClass(r.discoToPov),
            povToProposalClass:         this.cellClass(r.povToProposal),
            proposalToContractingClass: this.cellClass(r.proposalToContracting),
            contractingToWonClass:      this.cellClass(r.contractingToWon)
        }));
    }

    get hasRows() { return this.rows.length > 0; }

    fmt(val) {
        if (val == null) return 'N/A';
        return Math.round(val) + '%';
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
