import { LightningElement, api } from 'lwc';

export default class PipeGenCommitCard extends LightningElement {
    @api commit = {};

    handleDelete(evt) {
        this.dispatchEvent(new CustomEvent('deletecommit', {
            detail: { id: evt.currentTarget.dataset.id },
            bubbles: true,
            composed: true
        }));
    }

    handleMarkDone(evt) {
        this.dispatchEvent(new CustomEvent('markdone', {
            detail: { id: evt.currentTarget.dataset.id },
            bubbles: true,
            composed: true
        }));
    }
}
