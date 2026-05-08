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
            demoToDiscoClass:           this.cellClass(r.demoToDisco),
            discoToPovClass:            this.cellClass(r.discoToPov),
            povToProposalClass:         this.cellClass(r.povToProposal),
            proposalToContractingClass: this.cellClass(r.proposalToContracting),
            contractingToWonClass:      this.cellClass(r.contractingToWon)
        }));
    }

    get hasRows() { return this.rows.length > 0; }

    fmt(val) {
        // Apex returns null when there are no settled deals to convert
        // (open deals at that stage are excluded from the denominator).
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
}
