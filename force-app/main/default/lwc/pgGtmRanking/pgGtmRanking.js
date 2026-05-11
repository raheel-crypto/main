import { LightningElement, api, wire } from 'lwc';
import getGtmRanking from '@salesforce/apex/PGGtmInsightsController.getGtmRanking';

export default class PgGtmRanking extends LightningElement {
    @api metric = 'count';
    @api windowLabel = 'QTD';

    rawRows;

    @wire(getGtmRanking, { windowLabel: '$windowLabel' })
    wired({ data }) { if (data) this.rawRows = data; }

    get isAmount() { return this.metric === 'amount'; }
    get windowDisplay() { return this.windowLabel === 'CM' ? 'Current Month' : 'QTD'; }
    get hasRows() { return !!(this.rawRows && this.rawRows.length); }

    get rows() {
        if (!this.rawRows) return [];
        const isAmt = this.isAmount;
        const booked = (r) => Number(isAmt ? r.bookedAmount : r.booked) || 0;
        const sorted = [...this.rawRows].sort((a, b) => booked(b) - booked(a));

        return sorted.map((r, i) => {
            const bookedVal    = isAmt ? r.bookedAmount      : r.booked;
            const qualifiedVal = isAmt ? r.qualifiedAmount   : r.qualified;
            const passPct      = isAmt ? r.passThroughAmtPct : r.passThroughPct;
            const goalVal      = isAmt ? r.amountGoal        : r.goal;
            const attPct       = isAmt ? r.amountAttainmentPct : r.attainmentPct;
            return {
                ownerId: r.ownerId,
                ownerName: r.ownerName,
                rank: i + 1,
                bookedDisplay:    isAmt ? this.fmtCurrency(bookedVal)    : bookedVal,
                qualifiedDisplay: isAmt ? this.fmtCurrency(qualifiedVal) : qualifiedVal,
                passDisplay:      Number(bookedVal) > 0 ? this.fmtPct(passPct, 0) : 'N/A',
                goalDisplay:      isAmt ? this.fmtCurrency(goalVal)      : this.fmtNum(goalVal),
                attainmentDisplay: Number(goalVal) > 0 ? this.fmtPct(attPct, 0) : '—',
                rowClass: bookedVal === 0 ? 'pg-gtm-row pg-gtm-row--empty' : 'pg-gtm-row'
            };
        });
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
