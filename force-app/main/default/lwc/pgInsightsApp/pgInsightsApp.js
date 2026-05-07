import { LightningElement, api } from 'lwc';

export default class PgInsightsApp extends LightningElement {
    activeTab = 'recap';

    // Hidden by default. Toggle in Lightning App Builder via the
    // "Show Week/Month KPIs" checkbox to re-enable.
    @api showPacingKpis = false;
}
