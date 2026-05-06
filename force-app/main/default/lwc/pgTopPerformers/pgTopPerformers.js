import { LightningElement, wire } from 'lwc';
import getS1StatusQTD from '@salesforce/apex/PGInsightsController.getS1StatusQTD';
import getTopPerformersByPod from '@salesforce/apex/PGInsightsController.getTopPerformersByPod';

const POD_CLASS = {
    'ENT 1': 'pg-pod pg-pod--ent1',
    'ENT 2': 'pg-pod pg-pod--ent2',
    'MM/HV': 'pg-pod pg-pod--mmhv',
    'NV':    'pg-pod pg-pod--nv'
};

export default class PgTopPerformers extends LightningElement {
    rawPods;
    status;

    @wire(getTopPerformersByPod, { topN: 5 })
    wiredPods({ data }) {
        if (data) this.rawPods = data;
    }

    @wire(getS1StatusQTD)
    wiredStatus({ data }) {
        if (data) {
            this.status = {
                ...data,
                attainmentPct: (data.attainmentPct || 0).toFixed(2),
                goalMTDFmt: this.fmtNum(data.goalMTD)
            };
        }
    }

    get hasStatus() { return !!this.status; }
    get hasPods()   { return !!(this.rawPods && this.rawPods.length); }

    get pods() {
        if (!this.rawPods) return [];
        return this.rawPods.map(p => {
            const rows = (p.rows || []).map((r, i) => ({
                ...r,
                rank: i + 1,
                totalCount: (r.nbCount || 0) + (r.expCount || 0),
                attainmentDisplay: r.goal > 0
                    ? `${(r.attainmentPct || 0).toFixed(0)}%`
                    : '—'
            }));
            return {
                ...p,
                cardClass: POD_CLASS[p.pod] || 'pg-pod',
                totalCount: (p.totalNb || 0) + (p.totalExp || 0),
                goalMTDFmt: this.fmtNum(p.totalGoalMTD),
                attainmentDisplay: `${(p.attainmentPct || 0).toFixed(0)}%`,
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
}
