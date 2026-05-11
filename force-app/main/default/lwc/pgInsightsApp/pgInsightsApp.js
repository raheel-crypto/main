import { LightningElement, api } from 'lwc';

export default class PgInsightsApp extends LightningElement {
    activeTab = 'recap';

    // Hidden by default. Toggle in Lightning App Builder via the
    // "Show Week/Month KPIs" checkbox to re-enable.
    @api showPacingKpis = false;

    // Global # vs $ toggle for the Quarter Recap tab. Children read it
    // and pick which set of fields to render off the same Apex payload.
    metric = 'count'; // 'count' | 'amount'

    // Source-scope toggle: 'ALL' includes opps the AE owns regardless of
    // who booked them (matches team reporting); 'AE_SOURCED' applies
    // Booked_By_Role__c LIKE 'AE%' so only AE-booked opps count.
    sourceMode = 'ALL';

    get isCount()  { return this.metric === 'count'; }
    get isAmount() { return this.metric === 'amount'; }
    get isAllSource()      { return this.sourceMode === 'ALL'; }
    get isAeSourcedOnly()  { return this.sourceMode === 'AE_SOURCED'; }

    get countToggleClass() {
        return 'pg-toggle__btn' + (this.isCount  ? ' pg-toggle__btn--active' : '');
    }
    get amountToggleClass() {
        return 'pg-toggle__btn' + (this.isAmount ? ' pg-toggle__btn--active' : '');
    }
    get allSourceToggleClass() {
        return 'pg-toggle__btn' + (this.isAllSource ? ' pg-toggle__btn--active' : '');
    }
    get aeSourcedToggleClass() {
        return 'pg-toggle__btn' + (this.isAeSourcedOnly ? ' pg-toggle__btn--active' : '');
    }

    handleSelectCount()       { this.metric = 'count';  }
    handleSelectAmount()      { this.metric = 'amount'; }
    handleSelectAllSource()   { this.sourceMode = 'ALL'; }
    handleSelectAeSourced()   { this.sourceMode = 'AE_SOURCED'; }
}
