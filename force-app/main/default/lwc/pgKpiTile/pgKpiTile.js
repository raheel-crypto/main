import { LightningElement, api } from 'lwc';

export default class PgKpiTile extends LightningElement {
    @api label;
    @api value;
    @api delta;
    @api isPercent = false;
    // 'higher' = higher is better, 'lower' = lower is better
    @api deltaDirection = 'higher';

    get formattedValue() {
        if (this.value == null || this.value === '') return '—';
        if (this.isPercent) {
            const num = Number(this.value);
            return Number.isFinite(num) ? num.toFixed(2) + '%' : '—';
        }
        return this.value;
    }

    get hasDelta() {
        return this.delta !== null && this.delta !== undefined && this.delta !== '';
    }

    get deltaDisplay() {
        if (!this.hasDelta) return '';
        const num = Number(this.delta);
        if (!Number.isFinite(num)) return '';
        const arrow = num > 0 ? '▲' : num < 0 ? '▼' : '■';
        const formatted = this.isPercent ? `${num.toFixed(2)}%` : `${num}`;
        return `${arrow} ${formatted}`;
    }

    get deltaClass() {
        if (!this.hasDelta) return 'pg-delta';
        const num = Number(this.delta);
        if (!Number.isFinite(num) || num === 0) return 'pg-delta pg-delta--neutral';
        const isPositive = num > 0;
        const isGood = (this.deltaDirection === 'higher') ? isPositive : !isPositive;
        return isGood ? 'pg-delta pg-delta--good' : 'pg-delta pg-delta--bad';
    }
}
