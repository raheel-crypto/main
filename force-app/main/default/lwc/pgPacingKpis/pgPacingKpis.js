import { LightningElement, api, wire } from 'lwc';
import getPacingKpis from '@salesforce/apex/PGInsightsController.getPacingKpis';

export default class PgPacingKpis extends LightningElement {
    @api metric = 'count'; // 'count' | 'amount'
    @api sourceMode = 'ALL';

    rawWow;
    rawMom;

    @wire(getPacingKpis, { windowLabel: 'WoW', sourceMode: '$sourceMode' })
    wiredWow({ data }) { if (data) this.rawWow = data; }

    @wire(getPacingKpis, { windowLabel: 'MoM', sourceMode: '$sourceMode' })
    wiredMom({ data }) { if (data) this.rawMom = data; }

    get isAmount()    { return this.metric === 'amount'; }
    get displayKind() { return this.isAmount ? 'currency' : 'number'; }

    get wowData()  { return this.shape(this.rawWow); }
    get momData()  { return this.shape(this.rawMom); }
    get wowReady() { return !!this.rawWow; }
    get momReady() { return !!this.rawMom; }

    shape(raw) {
        if (!raw) return null;
        if (this.isAmount) {
            return {
                newBusiness:  raw.newBusinessAmount,
                expansion:    raw.expansionAmount,
                nbPctOfTotal: raw.nbAmtPctOfTotal,
                deltaNB:      raw.deltaNBAmount,
                deltaExp:     raw.deltaExpAmount,
                deltaPct:     raw.deltaAmtPct
            };
        }
        return {
            newBusiness:  raw.newBusiness,
            expansion:    raw.expansion,
            nbPctOfTotal: raw.nbPctOfTotal,
            deltaNB:      raw.deltaNB,
            deltaExp:     raw.deltaExp,
            deltaPct:     raw.deltaPct
        };
    }
}
