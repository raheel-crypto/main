import { LightningElement, api, wire } from 'lwc';
import getS1StatusQTD from '@salesforce/apex/PGInsightsController.getS1StatusQTD';
import getTopPerformersByPod from '@salesforce/apex/PGInsightsController.getTopPerformersByPod';

const POD_CLASS = {
    'Buyside': 'pg-pod pg-pod--buyside',
    'IB1':     'pg-pod pg-pod--ib1',
    'IB2':     'pg-pod pg-pod--ib2',
    'MM':      'pg-pod pg-pod--mm'
};

const TOP_N = 5;

export default class PgTopPerformers extends LightningElement {
    @api metric = 'count'; // 'count' | 'amount'

    rawPods;
    rawStatus;

    // Pull the full pod rosters (Apex caps at 50) so the LWC can re-sort
    // by # or $ without dropping candidates on the metric flip.
    @wire(getTopPerformersByPod, { topN: 50 })
    wiredPods({ data }) {
        if (data) this.rawPods = data;
    }

    @wire(getS1StatusQTD)
    wiredStatus({ data }) {
        if (data) this.rawStatus = data;
    }

    get isAmount() { return this.metric === 'amount'; }

    get hasStatus() { return !!this.rawStatus; }
    get hasPods()   { return !!(this.rawPods && this.rawPods.length); }

    fmtPct(val, decimals) {
        // Apex Decimal sometimes serializes as a string; coerce defensively
        // before calling toFixed so the LWC doesn't blow up at render.
        const n = Number(val);
        const d = decimals == null ? 0 : decimals;
        return Number.isFinite(n) ? `${n.toFixed(d)}%` : '0%';
    }

    get status() {
        if (!this.rawStatus) return null;
        const s = this.rawStatus;
        if (this.isAmount) {
            return {
                nbDisplay:           this.fmtCurrency(s.nbAmount),
                expDisplay:          this.fmtCurrency(s.expAmount),
                goalDisplay:         this.fmtCurrency(s.amountGoalQTD),
                attainmentDisplay:   this.fmtPct(s.amountAttainmentPct, 1),
                nbLabel:             'AE NB Stage 2+ ($)',
                expLabel:            'AE Exp Stage 2+ ($)'
            };
        }
        return {
            nbDisplay:           s.nbCount,
            expDisplay:          s.expCount,
            goalDisplay:         this.fmtNum(s.goalQTD),
            attainmentDisplay:   this.fmtPct(s.attainmentPct, 1),
            nbLabel:             'AE NB Stage 2+',
            expLabel:            'AE Exp Stage 2+'
        };
    }

    get pods() {
        if (!this.rawPods) return [];
        const isAmt = this.isAmount;
        const repTotal = (r) => isAmt
            ? Number(r.nbAmount || 0) + Number(r.expAmount || 0)
            : Number(r.nbCount  || 0) + Number(r.expCount  || 0);

        return this.rawPods.map(p => {
            const podCount = isAmt
                ? Number(p.totalNbAmount || 0) + Number(p.totalExpAmount || 0)
                : Number(p.totalNb || 0) + Number(p.totalExp || 0);
            const podGoal = Number(isAmt ? p.totalAmountGoalQTD : p.totalGoalQTD);
            const podAttainmentPct = isAmt ? p.amountAttainmentPct : p.attainmentPct;

            const sorted = [...(p.rows || [])].sort((a, b) => repTotal(b) - repTotal(a));
            const trimmed = sorted.slice(0, TOP_N);

            const rows = trimmed.map((r, i) => {
                const repValue = repTotal(r);
                const repGoal = Number(isAmt ? r.amountGoal : r.goal);
                const repAttPct = isAmt ? r.amountAttainmentPct : r.attainmentPct;
                return {
                    ownerId: r.ownerId,
                    ownerName: r.ownerName,
                    rank: i + 1,
                    totalDisplay: isAmt ? this.fmtCurrency(repValue) : repValue,
                    attainmentDisplay: repGoal > 0 ? this.fmtPct(repAttPct, 0) : '—'
                };
            });

            return {
                pod: p.pod,
                cardClass: POD_CLASS[p.pod] || 'pg-pod',
                totalDisplay:        isAmt ? this.fmtCurrency(podCount) : podCount,
                goalDisplay:         isAmt ? this.fmtCurrency(podGoal)  : this.fmtNum(podGoal),
                attainmentDisplay:   this.fmtPct(podAttainmentPct, 0),
                rows,
                empty: rows.length === 0
            };
        });
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
