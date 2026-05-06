import { LightningElement, wire } from 'lwc';
import getConversionHeatmap from '@salesforce/apex/PGInsightsController.getConversionHeatmap';

export default class PgConversionHeatmap extends LightningElement {
    rawRows;
    error;

    @wire(getConversionHeatmap)
    wired({ data, error }) {
        if (data) this.rawRows = data;
        if (error) this.error = error;
    }

    get rows() {
        if (!this.rawRows) return [];
        return this.rawRows.map(r => ({
            ...r,
            demoToDiscoFmt:           this.fmt(r.demoToDisco),
            discoToPovFmt:            this.fmt(r.discoToPov),
            povToProposalFmt:         this.fmt(r.povToProposal),
            proposalToContractingFmt: this.fmt(r.proposalToContracting),
            contractingToWonFmt:      this.fmt(r.contractingToWon),
            demoToDiscoClass:           this.cellClass(r.demoToDisco, r.demoCount),
            discoToPovClass:            this.cellClass(r.discoToPov, r.discoveryCount),
            povToProposalClass:         this.cellClass(r.povToProposal, r.povCount),
            proposalToContractingClass: this.cellClass(r.proposalToContracting, r.proposalCount),
            contractingToWonClass:      this.cellClass(r.contractingToWon, r.contractingCount)
        }));
    }

    get hasRows() { return this.rows.length > 0; }

    fmt(val) {
        if (val == null) return '—';
        return Math.round(val) + '%';
    }

    cellClass(val, denom) {
        if (denom == null || denom === 0) return 'pg-cell pg-cell--empty';
        if (val == null) return 'pg-cell pg-cell--empty';
        if (val >= 75) return 'pg-cell pg-cell--green';
        if (val >= 50) return 'pg-cell pg-cell--lime';
        if (val >= 30) return 'pg-cell pg-cell--yellow';
        return 'pg-cell pg-cell--red';
    }
}
