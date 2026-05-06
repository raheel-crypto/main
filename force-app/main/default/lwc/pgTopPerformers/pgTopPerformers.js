import { LightningElement, wire } from 'lwc';
import getS1StatusQTD from '@salesforce/apex/PGInsightsController.getS1StatusQTD';
import getTopPerformers from '@salesforce/apex/PGInsightsController.getTopPerformers';

const COLUMNS = [
    { label: 'Name', fieldName: 'ownerName', type: 'text' },
    { label: 'AE NB S1 Count', fieldName: 'nbCount', type: 'number',
        cellAttributes: { alignment: 'left' } },
    { label: 'AE Exp S1 Count', fieldName: 'expCount', type: 'number',
        cellAttributes: { alignment: 'left' } },
    { label: 'S1 Goal (MTD)', fieldName: 'goal', type: 'number',
        cellAttributes: { alignment: 'left' } },
    { label: 'Attainment',  fieldName: 'attainmentPct', type: 'percent',
        typeAttributes: { maximumFractionDigits: 1 },
        cellAttributes: { alignment: 'left' } }
];

export default class PgTopPerformers extends LightningElement {
    columns = COLUMNS;
    rows;
    status;

    @wire(getTopPerformers, { topN: 5 })
    wiredRows({ data, error }) {
        if (data) {
            // lightning-datatable percent type expects 0..1 range
            this.rows = data.map(r => ({
                ...r,
                attainmentPct: (r.attainmentPct || 0) / 100
            }));
        }
    }

    @wire(getS1StatusQTD)
    wiredStatus({ data }) {
        if (data) {
            this.status = {
                ...data,
                attainmentPct: (data.attainmentPct || 0).toFixed(2)
            };
        }
    }

    get hasRows() { return this.rows && this.rows.length > 0; }
    get hasStatus() { return !!this.status; }
}
