import { LightningElement, api } from 'lwc';

export default class PgGtmInsightsApp extends LightningElement {
    activeTab = 'recap';

    // # of opps vs $ pipeline — applies to all Quarter Recap widgets.
    metric = 'count';

    // Pass-through window for status panel + ranking: QTD (default) or CM.
    @api defaultWindow = 'QTD';
    windowSelection = 'QTD';

    connectedCallback() {
        if (this.defaultWindow) this.windowSelection = this.defaultWindow;
    }

    get isCount()  { return this.metric === 'count'; }
    get isAmount() { return this.metric === 'amount'; }
    get isQtd()    { return this.windowSelection === 'QTD'; }
    get isCm()     { return this.windowSelection === 'CM'; }

    get countToggleClass()  { return 'pg-toggle__btn' + (this.isCount  ? ' pg-toggle__btn--active' : ''); }
    get amountToggleClass() { return 'pg-toggle__btn' + (this.isAmount ? ' pg-toggle__btn--active' : ''); }
    get qtdToggleClass()    { return 'pg-toggle__btn' + (this.isQtd    ? ' pg-toggle__btn--active' : ''); }
    get cmToggleClass()     { return 'pg-toggle__btn' + (this.isCm     ? ' pg-toggle__btn--active' : ''); }

    handleSelectCount()  { this.metric = 'count';  }
    handleSelectAmount() { this.metric = 'amount'; }
    handleSelectQtd()    { this.windowSelection = 'QTD'; }
    handleSelectCm()     { this.windowSelection = 'CM';  }
}
