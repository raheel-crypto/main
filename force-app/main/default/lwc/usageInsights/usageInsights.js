import { LightningElement, api } from 'lwc';
import submitJob from '@salesforce/apex/RogoUsageInsightsController.submitJob';
import fetchJob from '@salesforce/apex/RogoUsageInsightsController.fetchJob';
import computeUpsell from '@salesforce/apex/UpsellSignalsService.compute';

const DEFAULT_POLL_MS = 2000;
const MAX_POLLS = 90;

export default class UsageInsights extends LightningElement {
    @api recordId;

    loading = false;
    error;
    statusLabel = '';
    metrics;
    rawAnswer;
    jobId;

    upsell;
    upsellWarningRows;
    narrativeLoading = false;
    narrativeSections;
    rawNarrative;

    get empty() {
        return !this.loading && !this.metrics && !this.error;
    }
    get accountHeader() {
        if (this.upsell && this.upsell.accountName) {
            const tierBit = this.upsell.accountTier ? ` · ${this.upsell.accountTier}` : '';
            return `${this.upsell.accountName}${tierBit}`;
        }
        if (this.metrics && this.metrics.accountName) {
            return `${this.metrics.accountName}`;
        }
        return null;
    }

    get dauWauDisplay()    { return fmtRatio(this.metrics && this.metrics.dauWau); }
    get wauEnrolledDisplay() { return fmtRatio(this.metrics && this.metrics.wauEnrolled); }
    get qpuDisplay()       { return fmtNumber(this.metrics && this.metrics.qpu); }
    get dauWauSub()        {
        if (!this.metrics) return '';
        return `DAU ${fmtInt(this.metrics.dau)} / WAU ${fmtInt(this.metrics.wau)}`;
    }
    get wauEnrolledSub()   {
        if (!this.metrics) return '';
        return `WAU ${fmtInt(this.metrics.wau)} / Enrolled ${fmtInt(this.metrics.enrolled)}`;
    }
    get qpuSub()           {
        if (!this.metrics) return '';
        return `${fmtInt(this.metrics.queries)} queries`;
    }

    get scoreBand() {
        if (!this.upsell) return '';
        const s = this.upsell.score;
        if (s >= 70) return 'Top expansion candidate';
        if (s >= 45) return 'Strong candidate — pursue actively';
        if (s >= 25) return 'Watch — re-evaluate next quarter';
        return 'Low signal';
    }

    get signalRows() {
        if (!this.upsell || !this.upsell.signals) return [];
        return this.upsell.signals.map((s) => {
            const weight = s.weight || 0;
            const pts = s.contributionPoints == null ? 0 : Number(s.contributionPoints);
            const hasBar = weight > 0 && s.status !== 'missing' && s.status !== 'pending';
            const fillPercent = weight > 0 ? Math.round((pts / weight) * 100) : 0;
            const pointsDisplay = s.status === 'pending'
                ? 'pending'
                : s.status === 'missing'
                    ? 'no data'
                    : `${pts.toFixed(1)} / ${weight}`;
            const pointsClass = s.status === 'pending' || s.status === 'missing'
                ? 'signal-points signal-points-muted'
                : 'signal-points';
            return {
                key: s.key,
                label: s.label,
                detail: s.detail,
                hasBar,
                fillPercent,
                pointsDisplay,
                pointsClass
            };
        });
    }

    async handleGenerate() {
        this.reset();
        this.loading = true;
        this.statusLabel = 'Submitting question to Rogo...';
        try {
            const job = await submitJob({ accountId: this.recordId });
            this.jobId = job.jobId;
            this.statusLabel = 'Job accepted, waiting for analysis...';
            const usageResult = await this.pollUntilTerminal(this.jobId, DEFAULT_POLL_MS, (r) => {
                if (typeof r.progress === 'number') {
                    this.statusLabel = `Analyzing usage... ${Math.round(r.progress * 100)}%`;
                }
            });
            if (!usageResult) return;

            this.rawAnswer = usageResult.rawAnswer;
            if (usageResult.metrics) {
                this.metrics = usageResult.metrics;
            } else {
                this.error = 'Usage job completed but no metrics could be parsed.';
                this.loading = false;
                return;
            }
            this.loading = false;

            await this.runUpsellFlow();
        } catch (e) {
            this.handleError(e);
        }
    }

    async runUpsellFlow() {
        try {
            const out = await computeUpsell({
                accountId: this.recordId,
                dauWauObserved: this.metrics.dauWau,
                wauEnrolledObserved: this.metrics.wauEnrolled,
                qpuObserved: this.metrics.qpu
            });
            this.upsell = out;
            this.upsellWarningRows = (out.warnings && out.warnings.length)
                ? out.warnings.map((w, i) => ({ id: `w${i}`, text: w }))
                : null;

            if (out.narrativeJobId) {
                this.narrativeLoading = true;
                const narrResult = await this.pollUntilTerminal(out.narrativeJobId, DEFAULT_POLL_MS, () => {});
                this.narrativeLoading = false;
                if (narrResult && narrResult.status === 'completed') {
                    this.rawNarrative = narrResult.rawAnswer;
                    this.narrativeSections = parseNarrative(narrResult.rawAnswer);
                }
            }
        } catch (e) {
            const msg = (e && e.body && e.body.message) || (e && e.message) || 'Upsell forecast failed';
            this.upsellWarningRows = [{ id: 'w0', text: msg }];
        }
    }

    async pollUntilTerminal(jobId, initialDelay, onProgress) {
        let delay = initialDelay;
        for (let i = 0; i < MAX_POLLS; i++) {
            await wait(delay);
            let result;
            try {
                result = await fetchJob({ jobId });
            } catch (e) {
                this.handleError(e);
                return null;
            }
            if (onProgress) onProgress(result);
            if (result.status === 'completed') return result;
            if (result.status === 'failed') {
                this.error = result.errorMessage ? `Job failed: ${result.errorMessage}` : 'Job failed';
                this.loading = false;
                return null;
            }
            delay = result.nextPollAfterMs || DEFAULT_POLL_MS;
        }
        this.error = 'Timed out waiting for Rogo analysis.';
        this.loading = false;
        return null;
    }

    reset() {
        this.error = undefined;
        this.metrics = undefined;
        this.rawAnswer = undefined;
        this.jobId = undefined;
        this.statusLabel = '';
        this.upsell = undefined;
        this.upsellWarningRows = undefined;
        this.narrativeLoading = false;
        this.narrativeSections = undefined;
        this.rawNarrative = undefined;
    }

    handleError(e) {
        this.loading = false;
        this.narrativeLoading = false;
        this.error =
            (e && e.body && e.body.message) ||
            (e && e.message) ||
            'Unexpected error';
    }
}

function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function fmtRatio(v) {
    if (v == null) return '—';
    return `${(Number(v) * 100).toFixed(1)}%`;
}

function fmtNumber(v) {
    if (v == null) return '—';
    return Number(v).toFixed(1);
}

function fmtInt(v) {
    if (v == null) return '—';
    return String(v);
}

function parseNarrative(md) {
    if (!md) return null;
    const sections = [];
    let current = null;
    for (const rawLine of md.split('\n')) {
        const line = rawLine.trim();
        if (!line) continue;
        if (line.startsWith('## ')) {
            current = { id: `s${sections.length}`, title: line.slice(3).trim(), items: [] };
            sections.push(current);
        } else if (current) {
            const cleaned = line
                .replace(/^\d+\.\s+/, '')
                .replace(/^[-*]\s+/, '')
                .replace(/\*\*(.+?)\*\*/g, '$1');
            current.items.push({
                id: `${current.id}i${current.items.length}`,
                text: cleaned
            });
        }
    }
    return sections.length ? sections : null;
}
