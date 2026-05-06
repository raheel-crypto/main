import { LightningElement, wire } from 'lwc';
import getPacingKpis from '@salesforce/apex/PGInsightsController.getPacingKpis';

export default class PgPacingKpis extends LightningElement {
    wowData;
    momData;
    wowError;
    momError;

    @wire(getPacingKpis, { windowLabel: 'WoW' })
    wiredWow({ data, error }) {
        if (data) this.wowData = data;
        if (error) this.wowError = error;
    }

    @wire(getPacingKpis, { windowLabel: 'MoM' })
    wiredMom({ data, error }) {
        if (data) this.momData = data;
        if (error) this.momError = error;
    }

    get wowReady()  { return !!this.wowData; }
    get momReady()  { return !!this.momData; }
}
