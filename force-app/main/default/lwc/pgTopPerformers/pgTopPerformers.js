import { LightningElement, api, wire } from 'lwc';
import getS1StatusQTD from '@salesforce/apex/PGInsightsController.getS1StatusQTD';
import getTopPerformersByPod from '@salesforce/apex/PGInsightsController.getTopPerformersByPod';

const POD_CLASS = {
    'Buyside': 'pg-pod pg-pod--buyside',
    'IB1':     'pg-pod pg-pod--ib1',
    'IB2':     'pg-pod pg-pod--ib2',
    'MM':      'pg-pod pg-pod--mm'
};

export default class PgTopPerformers extends LightningElement {
    @api metric = 'count'; // 'count' | 'amount'

    rawPods;
    rawStatus;

    @wire(getTopPerformersByPod, { topN: 5 })
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

    get status() {
        if (!this.rawStatus) return null;
        const s = this.rawStatus;
        if (this.isAmount) {
            return {
                nbDisplay:           this.fmtCurrency(s.nbAmount),
                expDisplay:          this.fmtCurrency(s.expAmount),
                goalDisplay:         this.fmtCurrency(s.amountGoalMTD),
                attainmentDisplay:   `${(s.amountAttainmentPct || 0).toFixed(1)}%`,
                nbLabel:             'AE NB Stage 2+ ($)',
                expLabel:            'AE Exp Stage 2+ ($)'
            };
        }
        return {
            nbDisplay:           s.nbCount,
            expDisplay:          s.expCount,
            goalDisplay:         this.fmtNum(s.goalMTD),
            attainmentDisplay:   `${(s.attainmentPct || 0).toFixed(1)}%`,
            nbLabel:             'AE NB Stage 2+',
            expLabel:            'AE Exp Stage 2+'
        };
    }

    get pods() {
        if (!this.rawPods) return [];
        return this.rawPods.map(p => {
            const isAmt = this.isAmount;
            const podCount = isAmt
                ? (p.totalNbAmount || 0) + (p.totalExpAmount || 0)
                : (p.totalNb || 0) + (p.totalExp || 0);
            const podGoal = isAmt ? p.totalAmountGoalMTD : p.totalGoalMTD;
            const podAttainmentPct = isAmt ? p.amountAttainmentPct : p.attainmentPct;

            const rows = (p.rows || []).map((r, i) => {
                const repCount = isAmt
                    ? (r.nbAmount || 0) + (r.expAmount || 0)
                    : (r.nbCount || 0) + (r.expCount || 0);
                const repGoal = isAmt ? r.amountGoal : r.goal;
                const repAttPct = isAmt ? r.amountAttainmentPct : r.attainmentPct;
                return {
                    ownerId: r.ownerId,
                    ownerName: r.ownerName,
                    rank: i + 1,
                    totalDisplay: isAmt ? this.fmtCurrency(repCount) : repCount,
                    attainmentDisplay: repGoal > 0
                        ? `${(repAttPct || 0).toFixed(0)}%`
                        : '—'
                };
            });

            return {
                pod: p.pod,
                cardClass: POD_CLASS[p.pod] || 'pg-pod',
                totalDisplay:        isAmt ? this.fmtCurrency(podCount) : podCount,
                goalDisplay:         isAmt ? this.fmtCurrency(podGoal)  : this.fmtNum(podGoal),
                attainmentDisplay:   `${(podAttainmentPct || 0).toFixed(0)}%`,
                rows,
                empty: rows.length === 0
            };
        });
    }

    fmtNum(n) {
        if (n == null) return '0';
        const v = Number(n);
        if (!Number.isFinite(v)) return '0';
        return v >= 100 ? Math.round(v).toString() : v.toFixed(1);
    }

    fmtCurrency(n) {
        if (n == null) return '$0';
        const v = Number(n);
        if (!Number.isFinite(v)) return '$0';
        if (v >= 1_000_000) return `$${(v / 1_000_000).toFixed(1)}M`;
        if (v >= 1_000)     return `$${(v / 1_000).toFixed(0)}K`;
        return `$${Math.round(v)}`;
    }
}
