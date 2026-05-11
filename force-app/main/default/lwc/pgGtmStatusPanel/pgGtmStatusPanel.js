import { LightningElement, api, wire } from 'lwc';
import getGtmStatus from '@salesforce/apex/PGGtmInsightsController.getGtmStatus';

export default class PgGtmStatusPanel extends LightningElement {
    @api metric = 'count';
    @api windowLabel = 'QTD';

    rawStatus;

    @wire(getGtmStatus, { windowLabel: '$windowLabel' })
    wired({ data }) { if (data) this.rawStatus = data; }

    get isAmount()    { return this.metric === 'amount'; }
    get hasStatus()   { return !!this.rawStatus; }
    get windowDisplay() { return this.windowLabel === 'CM' ? 'Current Month' : 'QTD'; }

    get status() {
        if (!this.rawStatus) return null;
        const s = this.rawStatus;
        const isAmt = this.isAmount;

        const booked    = isAmt ? s.bookedAmount    : s.booked;
        const qualified = isAmt ? s.qualifiedAmount : s.qualified;
        const passPct   = isAmt ? s.passThroughAmtPct : s.passThroughPct;
        const goal      = isAmt ? s.amountGoal       : s.goal;
        const attPct    = isAmt ? s.amountAttainmentPct : s.attainmentPct;

        return {
            bookedDisplay:    isAmt ? this.fmtCurrency(booked)    : booked,
            qualifiedDisplay: isAmt ? this.fmtCurrency(qualified) : qualified,
            passDisplay:      this.fmtPct(passPct, 1),
            goalDisplay:      isAmt ? this.fmtCurrency(goal)      : this.fmtNum(goal),
            attainmentDisplay: goal > 0 ? this.fmtPct(attPct, 1) : '—'
        };
    }

    fmtPct(val, decimals) {
        const n = Number(val);
        return Number.isFinite(n) ? `${n.toFixed(decimals == null ? 0 : decimals)}%` : '0%';
    }

    fmtNum(n) {
        const v = Number(n);
        if (!Number.isFinite(v)) return '0';
        return v >= 100 ? Math.round(v).toString() : v.toFixed(1);
    }

    fmtCurrency(n) {
        const v = Number(n);
        if (!Number.isFinite(v)) return '$0';
        if (v >= 1_000_000) return `$${(v / 1_000_000).toFixed(1)}M`;
        if (v >= 1_000)     return `$${(v / 1_000).toFixed(0)}K`;
        return `$${Math.round(v)}`;
    }
}
