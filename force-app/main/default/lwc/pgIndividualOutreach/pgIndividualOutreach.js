import { LightningElement, wire } from "lwc";
import getIndividualOutreach from "@salesforce/apex/PGInsightsController.getIndividualOutreach";

const SORTABLE = ['emails', 'calls', 'linkedin', 'meetings', 'total', 'ownerName'];

const LEFT_WINDOW_OPTIONS = [
    { label: 'Current Week',  value: 'CW' },
    { label: 'Prior Week',    value: 'PW' },
    { label: 'Current Month', value: 'CM' },
    { label: 'Prior Month',   value: 'PM' }
];

export default class PgIndividualOutreach extends LightningElement {
    leftWindow = 'CW';
    leftRowsRaw;
    qtdRowsRaw;

    leftSortBy = 'total';
    leftSortDir = 'desc';
    qtdSortBy = 'total';
    qtdSortDir = 'desc';

    groupByManager = false;

    leftWindowOptions = LEFT_WINDOW_OPTIONS;

    @wire(getIndividualOutreach, { windowLabel: '$leftWindow' })
    wiredLeft({ data }) {
        if (data) this.leftRowsRaw = data;
    }

    @wire(getIndividualOutreach, { windowLabel: 'QTD' })
    wiredQtd({ data }) {
        if (data) this.qtdRowsRaw = data;
    }

    handleToggleGroup(event)       { this.groupByManager = event.target.checked; }
    handleLeftWindowChange(event)  { this.leftWindow = event.detail.value; }

    get leftWindowLabel() {
        const opt = this.leftWindowOptions.find(o => o.value === this.leftWindow);
        return opt ? opt.label : 'Current Week';
    }

    get leftCardTitle() {
        return `Individual Outreach · ${this.leftWindowLabel}`;
    }

    get leftRows()  { return this.decorateRows(this.leftRowsRaw, this.leftSortBy, this.leftSortDir); }
    get qtdRows()   { return this.decorateRows(this.qtdRowsRaw,  this.qtdSortBy,  this.qtdSortDir); }

    get leftGroups() { return this.groupByManager ? this.buildGroups(this.leftRows) : null; }
    get qtdGroups()  { return this.groupByManager ? this.buildGroups(this.qtdRows)  : null; }

    get hasLeftRows() { return this.leftRows.length > 0; }
    get hasQtdRows()  { return this.qtdRows.length > 0; }

    get leftTotals() { return this.computeTotals(this.leftRowsRaw); }
    get qtdTotals()  { return this.computeTotals(this.qtdRowsRaw); }

    decorateRows(rows, sortBy, sortDir) {
        if (!rows || !rows.length) return [];
        const max = (key) => Math.max(...rows.map(r => r[key] || 0)) || 1;
        const m = {
            emails: max('emails'),
            calls: max('calls'),
            linkedin: max('linkedin'),
            meetings: max('meetings'),
            total: max('total')
        };
        const factor = sortDir === 'asc' ? 1 : -1;
        const sorted = [...rows].sort((a, b) => {
            const av = a[sortBy] ?? 0;
            const bv = b[sortBy] ?? 0;
            if (typeof av === 'string' || typeof bv === 'string') {
                return String(av).localeCompare(String(bv)) * factor;
            }
            if (av > bv) return 1 * factor;
            if (av < bv) return -1 * factor;
            return 0;
        });
        return sorted.map(r => ({
            ...r,
            emailsBar:   `width: ${((r.emails || 0)   / m.emails)   * 100}%`,
            callsBar:    `width: ${((r.calls || 0)    / m.calls)    * 100}%`,
            linkedinBar: `width: ${((r.linkedin || 0) / m.linkedin) * 100}%`,
            meetingsBar: `width: ${((r.meetings || 0) / m.meetings) * 100}%`,
            totalBar:    `width: ${((r.total || 0)    / m.total)    * 100}%`
        }));
    }

    buildGroups(rows) {
        if (!rows || !rows.length) return [];
        const buckets = new Map();
        for (const r of rows) {
            const key = r.managerId || '__unmanaged__';
            const display = r.managerName || 'No Manager';
            let b = buckets.get(key);
            if (!b) {
                b = {
                    key, managerName: display, rows: [],
                    emailsSum: 0, callsSum: 0, linkedinSum: 0, meetingsSum: 0, totalSum: 0
                };
                buckets.set(key, b);
            }
            b.rows.push(r);
            b.emailsSum   += r.emails || 0;
            b.callsSum    += r.calls || 0;
            b.linkedinSum += r.linkedin || 0;
            b.meetingsSum += r.meetings || 0;
            b.totalSum    += r.total || 0;
        }
        return Array.from(buckets.values()).sort((a, b) => b.totalSum - a.totalSum);
    }

    computeTotals(rows) {
        if (!rows || !rows.length) return null;
        const sum = (key) => rows.reduce((a, r) => a + (r[key] || 0), 0);
        return {
            emails: sum('emails'),
            calls: sum('calls'),
            linkedin: sum('linkedin'),
            meetings: sum('meetings'),
            total: sum('total')
        };
    }

    handleLeftSort(event) {
        const field = event.currentTarget.dataset.field;
        if (!SORTABLE.includes(field)) return;
        if (this.leftSortBy === field) {
            this.leftSortDir = this.leftSortDir === 'asc' ? 'desc' : 'asc';
        } else {
            this.leftSortBy = field;
            this.leftSortDir = field === 'ownerName' ? 'asc' : 'desc';
        }
    }

    handleQtdSort(event) {
        const field = event.currentTarget.dataset.field;
        if (!SORTABLE.includes(field)) return;
        if (this.qtdSortBy === field) {
            this.qtdSortDir = this.qtdSortDir === 'asc' ? 'desc' : 'asc';
        } else {
            this.qtdSortBy = field;
            this.qtdSortDir = field === 'ownerName' ? 'asc' : 'desc';
        }
    }
}
