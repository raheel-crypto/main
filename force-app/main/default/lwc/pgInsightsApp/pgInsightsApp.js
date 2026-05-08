import { LightningElement, api } from 'lwc';

export default class PgInsightsApp extends LightningElement {
    activeTab = 'recap';

    // Hidden by default. Toggle in Lightning App Builder via the
    // "Show Week/Month KPIs" checkbox to re-enable.
    @api showPacingKpis = false;

    // Global # vs $ toggle for the Quarter Recap tab. Children read it
    // and pick which set of fields to render off the same Apex payload.
    metric = 'count'; // 'count' | 'amount'

    get isCount()  { return this.metric === 'count'; }
    get isAmount() { return this.metric === 'amount'; }

    get countToggleClass() {
        return 'pg-toggle__btn' + (this.isCount  ? ' pg-toggle__btn--active' : '');
    }
    get amountToggleClass() {
        return 'pg-toggle__btn' + (this.isAmount ? ' pg-toggle__btn--active' : '');
    }

    handleSelectCount()  { this.metric = 'count';  }
    handleSelectAmount() { this.metric = 'amount'; }
}
