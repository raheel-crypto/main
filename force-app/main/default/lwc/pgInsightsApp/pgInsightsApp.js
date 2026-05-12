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

    // Date-logic toggle:
    //   'OPP_HISTORY'  — bucket by first OpportunityHistory Stage 2+ entry
    //   'CREATED_DATE' — bucket by Opportunity.CreatedDate (currently @ Stage 2+)
    dateMode = 'OPP_HISTORY';

    get isCount()  { return this.metric === 'count'; }
    get isAmount() { return this.metric === 'amount'; }
    get isAllSource()      { return this.sourceMode === 'ALL'; }
    get isAeSourcedOnly()  { return this.sourceMode === 'AE_SOURCED'; }
    get isOppHistory()     { return this.dateMode === 'OPP_HISTORY'; }
    get isCreatedDate()    { return this.dateMode === 'CREATED_DATE'; }

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
    get oppHistoryToggleClass() {
        return 'pg-toggle__btn' + (this.isOppHistory ? ' pg-toggle__btn--active' : '');
    }
    get createdDateToggleClass() {
        return 'pg-toggle__btn' + (this.isCreatedDate ? ' pg-toggle__btn--active' : '');
    }

    handleSelectCount()        { this.metric = 'count';  }
    handleSelectAmount()       { this.metric = 'amount'; }
    handleSelectAllSource()    { this.sourceMode = 'ALL'; }
    handleSelectAeSourced()    { this.sourceMode = 'AE_SOURCED'; }
    handleSelectOppHistory()   { this.dateMode = 'OPP_HISTORY'; }
    handleSelectCreatedDate()  { this.dateMode = 'CREATED_DATE'; }
}
