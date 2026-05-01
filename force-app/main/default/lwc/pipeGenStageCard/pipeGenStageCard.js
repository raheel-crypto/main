import { LightningElement, api } from 'lwc';

export default class PipeGenStageCard extends LightningElement {
    @api stage = {};

    get stageCardClass() {
        const name = this.stage.stageName || '';
        let cls = 'stage-card';
        if (this.stage.isClosedWon)      cls += ' stage-card--won';
        else if (name.startsWith('5'))   cls += ' stage-card--contracting';
        else if (name.startsWith('4'))   cls += ' stage-card--proposal';
        else if (name.startsWith('3'))   cls += ' stage-card--pov';
        else if (name.startsWith('2'))   cls += ' stage-card--discovery';
        else                             cls += ' stage-card--qualify';
        return cls;
    }

    get dealLabel() {
        const n = this.stage.oppCount || 0;
        return `${n} deal${n !== 1 ? 's' : ''}`;
    }
}
