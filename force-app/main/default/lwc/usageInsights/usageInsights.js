import { LightningElement, api } from 'lwc';
import submitJob from '@salesforce/apex/RogoUsageInsightsController.submitJob';
import fetchJob from '@salesforce/apex/RogoUsageInsightsController.fetchJob';
import computeUpsell from '@salesforce/apex/UpsellSignalsService.compute';
import getLastInsight from '@salesforce/apex/UpsellSignalsService.getLastInsight';
import saveInsight from '@salesforce/apex/UpsellSignalsService.saveInsight';

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

    hydrating = true;
    lastRunAt;
    lastRunByName;

    connectedCallback() {
        this.hydrateFromCache();
    }

    async hydrateFromCache() {
        if (!this.recordId) {
            this.hydrating = false;
            return;
        }
        try {
            const saved = await getLastInsight({ accountId: this.recordId });
            if (saved && saved.payloadJson) {
                const payload = JSON.parse(saved.payloadJson);
                this.metrics = normalizeMetrics(payload.metrics);
                this.upsell = payload.upsell;
                this.rawAnswer = payload.rawAnswer;
                this.rawNarrative = payload.rawNarrative;
                this.narrativeSections = parseNarrative(payload.rawNarrative);
                this.lastRunAt = toIsoOrNull(saved.lastRunAt);
                this.lastRunByName = saved.lastRunByName;
                this.upsellWarningRows = (this.upsell && this.upsell.warnings && this.upsell.warnings.length)
                    ? this.upsell.warnings.map((w, i) => ({ id: `w${i}`, text: w }))
                    : null;
            }
        } catch (e) {
            // Object/permissions may not be available yet — silently skip
        } finally {
            this.hydrating = false;
        }
    }

    get buttonLabel() {
        return this.lastRunAt ? 'Refresh' : 'Generate Insights';
    }

    get hasLastRun() {
        return !this.loading && !!this.lastRunAt;
    }

    get empty() {
        return !this.loading && !this.hydrating && !this.metrics && !this.error;
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

    get dauWauDisplay()      { return fmtRatio(statMean(this.metrics, 'dauWau')); }
    get wauEnrolledDisplay() { return fmtRatio(statMean(this.metrics, 'wauEnrolled')); }
    get qpuDisplay()         { return fmtNumber(statMean(this.metrics, 'qpu')); }

    get dauWauSub()        { return fmtRangeRatio(this.metrics && this.metrics.dauWau); }
    get wauEnrolledSub()   {
        const range = fmtRangeRatio(this.metrics && this.metrics.wauEnrolled);
        const enrolled = this.metrics && this.metrics.enrolled;
        if (range && enrolled != null) return `${range} · ${enrolled} enrolled`;
        if (enrolled != null) return `${enrolled} enrolled`;
        return range;
    }
    get qpuSub()           { return fmtRangeNumber(this.metrics && this.metrics.qpu); }

    get dauWauCommentary()      { return statCommentary(this.metrics, 'dauWau'); }
    get wauEnrolledCommentary() { return statCommentary(this.metrics, 'wauEnrolled'); }
    get qpuCommentary()         { return statCommentary(this.metrics, 'qpu'); }

    get scoreBand() {
        if (!this.upsell) return '';
        const s = this.upsell.score;
        if (s >= 70) return 'Top expansion candidate';
        if (s >= 45) return 'Strong candidate — pursue actively';
        if (s >= 25) return 'Watch — re-evaluate next quarter';
        return 'Low signal';
    }

    get scoreCardClass() {
        const base = 'score-card';
        if (!this.upsell) return base;
        const s = this.upsell.score;
        if (s >= 70) return `${base} score-top`;
        if (s >= 45) return `${base} score-strong`;
        if (s >= 25) return `${base} score-watch`;
        return `${base} score-low`;
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
            if (usageResult.status !== 'completed') {
                this.error = usageResult.errorMessage || 'Usage job did not complete';
                this.loading = false;
                return;
            }

            this.rawAnswer = usageResult.rawAnswer;
            if (!usageResult.metrics) {
                this.error = 'Usage job completed but no metrics could be parsed.';
                this.loading = false;
                return;
            }
            this.metrics = usageResult.metrics;
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
                dauWauObserved: statMean(this.metrics, 'dauWau'),
                wauEnrolledObserved: statMean(this.metrics, 'wauEnrolled'),
                qpuObserved: statMean(this.metrics, 'qpu')
            });
            this.upsell = out;
            const warnings = (out.warnings && out.warnings.length)
                ? out.warnings.map((w, i) => ({ id: `w${i}`, text: w }))
                : [];

            if (out.narrativeJobId) {
                this.narrativeLoading = true;
                const narrResult = await this.pollUntilTerminal(out.narrativeJobId, DEFAULT_POLL_MS, () => {});
                this.narrativeLoading = false;
                if (narrResult.status === 'completed' && narrResult.rawAnswer) {
                    this.rawNarrative = narrResult.rawAnswer;
                    this.narrativeSections = parseNarrative(narrResult.rawAnswer);
                } else {
                    warnings.push({
                        id: 'narrativeFail',
                        text: 'CSM recommendation unavailable — ' + (narrResult.errorMessage || 'narrative job did not complete') +
                              '. The score and signals above are still valid.'
                    });
                }
            }
            this.upsellWarningRows = warnings.length ? warnings : null;
            await this.persist();
        } catch (e) {
            const msg = (e && e.body && e.body.message) || (e && e.message) || 'Upsell forecast failed';
            this.upsellWarningRows = [{ id: 'w0', text: msg }];
        }
    }

    async persist() {
        if (!this.upsell) return;
        try {
            const payload = JSON.stringify({
                metrics: this.metrics,
                upsell: this.upsell,
                rawAnswer: this.rawAnswer,
                rawNarrative: this.rawNarrative
            });
            const saved = await saveInsight({
                accountId: this.recordId,
                payloadJson: payload,
                score: this.upsell.score
            });
            if (saved) {
                this.lastRunAt = toIsoOrNull(saved.lastRunAt);
                this.lastRunByName = saved.lastRunByName;
            }
        } catch (e) {
            // Don't fail the UI on save errors
            const msg = (e && e.body && e.body.message) || (e && e.message) || 'Save failed';
            const existing = this.upsellWarningRows || [];
            this.upsellWarningRows = existing.concat({ id: `wSave`, text: 'Could not cache result: ' + msg });
        }
    }

    // Returns a plain result object; does NOT mutate state. Callers decide how
    // to react. Possible terminal statuses: completed, failed, not_found,
    // timeout, callout_error.
    async pollUntilTerminal(jobId, initialDelay, onProgress) {
        const MAX_NOT_FOUND_RETRIES = 5;
        let delay = initialDelay;
        let notFoundRetries = 0;
        for (let i = 0; i < MAX_POLLS; i++) {
            await wait(delay);
            let result;
            try {
                result = await fetchJob({ jobId });
            } catch (e) {
                return {
                    status: 'callout_error',
                    errorMessage: (e && e.body && e.body.message) || (e && e.message) || 'Callout error'
                };
            }
            if (result.status === 'not_found') {
                notFoundRetries++;
                if (notFoundRetries >= MAX_NOT_FOUND_RETRIES) {
                    return {
                        status: 'not_found',
                        errorMessage: 'Rogo could not find this job after ' + MAX_NOT_FOUND_RETRIES +
                            ' retries (likely a Cloud Run instance routing issue, or the job expired).'
                    };
                }
                // 404 on first polls is usually instance-routing on Cloud Run;
                // back off and try again.
                delay = Math.min(delay * 2, 8000);
                continue;
            }
            if (onProgress) onProgress(result);
            if (result.status === 'completed') return result;
            if (result.status === 'failed') {
                return {
                    status: 'failed',
                    errorMessage: result.errorMessage || 'Job failed'
                };
            }
            delay = result.nextPollAfterMs || DEFAULT_POLL_MS;
        }
        return { status: 'timeout', errorMessage: 'Timed out waiting for Rogo analysis.' };
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
        // intentionally NOT clearing lastRunAt / lastRunByName — we want the
        // previous timestamp visible until the new run completes and overwrites it
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

function statMean(metrics, key) {
    if (!metrics || !metrics[key]) return null;
    const stat = metrics[key];
    if (typeof stat === 'number') return stat;
    return stat.mean != null ? Number(stat.mean) : null;
}

function statCommentary(metrics, key) {
    if (!metrics || !metrics[key] || typeof metrics[key] !== 'object') return '';
    return metrics[key].commentary || '';
}

function fmtRangeRatio(stat) {
    if (!stat || typeof stat !== 'object') return '';
    const lo = stat.min;
    const hi = stat.max;
    if (lo == null || hi == null) return '';
    return `Range ${(Number(lo) * 100).toFixed(1)}% – ${(Number(hi) * 100).toFixed(1)}%`;
}

function fmtRangeNumber(stat) {
    if (!stat || typeof stat !== 'object') return '';
    const lo = stat.min;
    const hi = stat.max;
    if (lo == null || hi == null) return '';
    return `Range ${Number(lo).toFixed(0)} – ${Number(hi).toFixed(0)}`;
}

// Apex returns DateTime as either an ISO 8601 string or a Long (epoch ms)
// depending on the API version. Coerce both to a JS-Date-parseable ISO
// string so lightning-relative-date-time doesn't render 'Invalid date'.
function toIsoOrNull(v) {
    if (v == null) return null;
    const d = new Date(v);
    return isNaN(d.getTime()) ? null : d.toISOString();
}

// Tolerate the previous flat-number shape in cached records by wrapping each
// metric as a mean-only stat so the new tile renders without breaking.
function normalizeMetrics(m) {
    if (!m) return m;
    for (const k of ['dauWau', 'wauEnrolled', 'qpu']) {
        if (typeof m[k] === 'number') {
            m[k] = { mean: m[k] };
        }
    }
    return m;
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
