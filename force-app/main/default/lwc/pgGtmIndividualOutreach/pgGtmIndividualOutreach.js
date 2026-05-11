import { LightningElement, wire } from "lwc";
import getIndividualOutreach from "@salesforce/apex/PGGtmInsightsController.getIndividualOutreach";

const SORTABLE = ['emails', 'calls', 'linkedin', 'meetings', 'total', 'ownerName'];

export default class PgGtmIndividualOutreach extends LightningElement {
    cwRowsRaw;
    qtdRowsRaw;

    cwSortBy = 'total';
    cwSortDir = 'desc';
    qtdSortBy = 'total';
    qtdSortDir = 'desc';

    groupByManager = false;

    @wire(getIndividualOutreach, { windowLabel: 'CW' })
    wiredCw({ data }) {
        if (data) this.cwRowsRaw = data;
    }

    @wire(getIndividualOutreach, { windowLabel: 'QTD' })
    wiredQtd({ data }) {
        if (data) this.qtdRowsRaw = data;
    }

    handleToggleGroup(event) { this.groupByManager = event.target.checked; }

    get cwRows() {
        return this.decorateRows(this.cwRowsRaw, this.cwSortBy, this.cwSortDir);
    }

    get qtdRows() {
        return this.decorateRows(this.qtdRowsRaw, this.qtdSortBy, this.qtdSortDir);
    }

    get cwGroups() {
        return this.groupByManager ? this.buildGroups(this.cwRows) : null;
    }

    get qtdGroups() {
        return this.groupByManager ? this.buildGroups(this.qtdRows) : null;
    }

    get hasCwRows()  { return this.cwRows.length > 0; }
    get hasQtdRows() { return this.qtdRows.length > 0; }

    get cwTotals() { return this.computeTotals(this.cwRowsRaw); }
    get qtdTotals() { return this.computeTotals(this.qtdRowsRaw); }

    buildGroups(rows) {
        if (!rows || !rows.length) return [];
        const buckets = new Map();
        for (const r of rows) {
            const key = r.managerId || '__unmanaged__';
            const display = r.managerName || 'No Manager';
            let b = buckets.get(key);
            if (!b) {
                b = {
                    key,
                    managerName: display,
                    rows: [],
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
        const groups = Array.from(buckets.values());
        groups.sort((a, b) => b.totalSum - a.totalSum);
        return groups;
    }

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

    handleCwSort(event) {
        const field = event.currentTarget.dataset.field;
        if (!SORTABLE.includes(field)) return;
        if (this.cwSortBy === field) {
            this.cwSortDir = this.cwSortDir === 'asc' ? 'desc' : 'asc';
        } else {
            this.cwSortBy = field;
            this.cwSortDir = field === 'ownerName' ? 'asc' : 'desc';
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
