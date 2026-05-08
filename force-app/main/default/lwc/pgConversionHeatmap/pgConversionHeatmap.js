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
                    rowClass: o.reachedTarget ? 'pg-drill__row pg-drill__row--reached' : 'pg-drill__row',
                    statusLabel: o.reachedTarget ? 'Advanced' : (o.isClosed ? 'Closed without advancing' : 'Open at stage')
                }));
                this.drillLoading = false;
            })
            .catch(() => { this.drillLoading = false; });
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
