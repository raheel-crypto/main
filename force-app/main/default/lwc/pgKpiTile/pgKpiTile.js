import { LightningElement, api } from 'lwc';

export default class PgKpiTile extends LightningElement {
    @api label;
    @api value;
    @api delta;
    @api isPercent = false;
    // 'number' (default — passes through as integer-ish), 'currency' ($1.2M / $120K)
    @api displayKind = 'number';
    // 'higher' = higher is better, 'lower' = lower is better
    @api deltaDirection = 'higher';

    get formattedValue() {
        if (this.value == null || this.value === '') return '—';
        if (this.isPercent) {
            const num = Number(this.value);
            return Number.isFinite(num) ? num.toFixed(2) + '%' : '—';
        }
        if (this.displayKind === 'currency') return this.fmtCurrency(this.value);
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
        let formatted;
        if (this.isPercent) formatted = `${num.toFixed(2)}%`;
        else if (this.displayKind === 'currency') formatted = this.fmtCurrency(Math.abs(num));
        else formatted = `${num}`;
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

    fmtCurrency(n) {
        const v = Number(n);
        if (!Number.isFinite(v)) return '$0';
        if (v >= 1_000_000) return `$${(v / 1_000_000).toFixed(1)}M`;
        if (v >= 1_000)     return `$${(v / 1_000).toFixed(0)}K`;
        return `$${Math.round(v)}`;
    }
}
