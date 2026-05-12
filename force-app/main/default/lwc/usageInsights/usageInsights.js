import { LightningElement, api } from 'lwc';
import submitJob from '@salesforce/apex/RogoUsageInsightsController.submitJob';
import fetchJob from '@salesforce/apex/RogoUsageInsightsController.fetchJob';

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

    get empty() {
        return !this.loading && !this.metrics && !this.error;
    }

    get dauWauDisplay() {
        return formatRatio(this.metrics && this.metrics.dauWau);
    }
    get wauEnrolledDisplay() {
        return formatRatio(this.metrics && this.metrics.wauEnrolled);
    }
    get qpuDisplay() {
        return formatNumber(this.metrics && this.metrics.qpu);
    }
    get dauWauSub() {
        if (!this.metrics) return '';
        return `DAU ${formatInt(this.metrics.dau)} / WAU ${formatInt(this.metrics.wau)}`;
    }
    get wauEnrolledSub() {
        if (!this.metrics) return '';
        return `WAU ${formatInt(this.metrics.wau)} / Enrolled ${formatInt(this.metrics.enrolled)}`;
    }
    get qpuSub() {
        if (!this.metrics) return '';
        return `${formatInt(this.metrics.queries)} queries`;
    }

    async handleGenerate() {
        this.reset();
        this.loading = true;
        this.statusLabel = 'Submitting question to Rogo...';
        try {
            const job = await submitJob({ accountId: this.recordId });
            this.jobId = job.jobId;
            this.statusLabel = 'Job accepted, waiting for analysis...';
            await this.pollUntilTerminal(job.nextPollAfterMs || DEFAULT_POLL_MS);
        } catch (e) {
            this.handleError(e);
        }
    }

    async pollUntilTerminal(initialDelay) {
        let delay = initialDelay;
        for (let i = 0; i < MAX_POLLS; i++) {
            await wait(delay);
            let result;
            try {
                result = await fetchJob({ jobId: this.jobId });
            } catch (e) {
                this.handleError(e);
                return;
            }
            if (typeof result.progress === 'number') {
                this.statusLabel = `Analyzing... ${Math.round(result.progress * 100)}%`;
            }
            if (result.status === 'completed') {
                this.rawAnswer = result.rawAnswer;
                if (result.metrics) {
                    this.metrics = result.metrics;
                } else {
                    this.error = 'Job completed but no metrics could be parsed from the answer. See raw response.';
                }
                this.loading = false;
                return;
            }
            if (result.status === 'failed') {
                this.error = result.errorMessage
                    ? `Job failed: ${result.errorMessage}`
                    : 'Job failed';
                this.loading = false;
                return;
            }
            delay = result.nextPollAfterMs || DEFAULT_POLL_MS;
        }
        this.error = 'Timed out waiting for Rogo analysis.';
        this.loading = false;
    }

    reset() {
        this.error = undefined;
        this.metrics = undefined;
        this.rawAnswer = undefined;
        this.jobId = undefined;
        this.statusLabel = '';
    }

    handleError(e) {
        this.loading = false;
        this.error =
            (e && e.body && e.body.message) ||
            (e && e.message) ||
            'Unexpected error';
    }
}

function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatRatio(v) {
    if (v == null) return '—';
    return `${(Number(v) * 100).toFixed(1)}%`;
}

function formatNumber(v) {
    if (v == null) return '—';
    return Number(v).toFixed(1);
}

function formatInt(v) {
    if (v == null) return '—';
    return String(v);
}
