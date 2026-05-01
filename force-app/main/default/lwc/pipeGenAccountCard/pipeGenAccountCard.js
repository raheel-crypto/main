import { LightningElement, api } from 'lwc';

export default class PipeGenAccountCard extends LightningElement {
    @api account = {};
    @api mode = 'dashboard'; // 'dashboard' | 'selectable'

    get isDashboard() { return this.mode === 'dashboard'; }

    handleToggle(evt) {
        this.dispatchEvent(new CustomEvent('cardtoggle', {
            detail: { id: this.account.id },
            bubbles: true,
            composed: true
        }));
    }
}
