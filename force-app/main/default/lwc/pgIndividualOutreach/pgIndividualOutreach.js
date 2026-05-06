import { LightningElement, wire } from 'lwc';
import getIndividualOutreach from '@salesforce/apex/PGInsightsController.getIndividualOutreach';

const COLUMNS = [
    { label: 'Name', fieldName: 'ownerName', type: 'text', sortable: true },
    { label: 'OB Emails', fieldName: 'emails', type: 'number', sortable: true,
        cellAttributes: { alignment: 'left' } },
    { label: 'OB Calls', fieldName: 'calls', type: 'number', sortable: true,
        cellAttributes: { alignment: 'left' } },
    { label: 'OB LinkedIn', fieldName: 'linkedin', type: 'number', sortable: true,
        cellAttributes: { alignment: 'left' } },
    { label: 'Meetings', fieldName: 'meetings', type: 'number', sortable: true,
        cellAttributes: { alignment: 'left' } },
    { label: 'Total OB', fieldName: 'total', type: 'number', sortable: true,
        cellAttributes: { alignment: 'left' } }
];

export default class PgIndividualOutreach extends LightningElement {
    columns = COLUMNS;
    cwRows;
    qtdRows;

    cwSortBy = 'total';
    cwSortDir = 'desc';
    qtdSortBy = 'total';
    qtdSortDir = 'desc';

    @wire(getIndividualOutreach, { windowLabel: 'CW' })
    wiredCw({ data }) {
        if (data) this.cwRows = [...data];
    }

    @wire(getIndividualOutreach, { windowLabel: 'QTD' })
    wiredQtd({ data }) {
        if (data) this.qtdRows = [...data];
    }

    get cwTotals() { return this.computeTotals(this.cwRows); }
    get qtdTotals() { return this.computeTotals(this.qtdRows); }

    computeTotals(rows) {
        if (!rows || !rows.length) return null;
        const sum = (key) => rows.reduce((a, r) => a + (r[key] || 0), 0);
        return {
            emails: sum('emails'),
            calls: sum('calls'),
            linkedin: sum('linkedin'),
            meetings: sum('meetings'),
            total: sum('total')
        };
    }

    handleCwSort(event) {
        this.cwSortBy = event.detail.fieldName;
        this.cwSortDir = event.detail.sortDirection;
        this.cwRows = this.sortRows(this.cwRows, this.cwSortBy, this.cwSortDir);
    }

    handleQtdSort(event) {
        this.qtdSortBy = event.detail.fieldName;
        this.qtdSortDir = event.detail.sortDirection;
        this.qtdRows = this.sortRows(this.qtdRows, this.qtdSortBy, this.qtdSortDir);
    }

    sortRows(rows, field, dir) {
        if (!rows) return rows;
        const factor = dir === 'asc' ? 1 : -1;
        return [...rows].sort((a, b) => {
            const av = a[field] ?? 0;
            const bv = b[field] ?? 0;
            if (av > bv) return 1 * factor;
            if (av < bv) return -1 * factor;
            return 0;
        });
    }
}
