import { LightningElement, api, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';
import getStageProgressByQuarter from '@salesforce/apex/PGInsightsController.getStageProgressByQuarter';
import getStageProgressByWeek    from '@salesforce/apex/PGInsightsController.getStageProgressByWeek';

export default class PgStageProgressChart extends LightningElement {
    @api metric = 'count'; // 'count' | 'amount'

    grouping = 'week'; // 'week' | 'quarter'

    get isWeekView() { return this.grouping === 'week'; }
    get weekToggleClass() {
        return 'pg-mini-toggle__btn' + (this.isWeekView    ? ' pg-mini-toggle__btn--active' : '');
    }
    get quarterToggleClass() {
        return 'pg-mini-toggle__btn' + (!this.isWeekView   ? ' pg-mini-toggle__btn--active' : '');
    }

    handleSelectWeek()    { this.grouping = 'week';    }
    handleSelectQuarter() { this.grouping = 'quarter'; }

    get title() {
        if (this.isWeekView) {
            return this.metric === 'amount'
                ? 'AE Qualified Stage 2+ Pipeline ($) | Per Week (this Q)'
                : 'AE Qualified Stage 2+ Progress | Per Week (this Q)';
        }
        return this.metric === 'amount'
            ? 'AE Qualified Stage 2+ Pipeline ($) | Last 6 Quarters'
            : 'AE Qualified Stage 2+ Progress | Last 6 Quarters';
    }

    chart;
    chartJsLoaded = false;
    rowsByQuarter = [];
    rowsByWeek = [];
    error;

    @wire(getStageProgressByQuarter, { numQuarters: 6 })
    wiredQuarter({ data, error }) {
        if (data) {
            this.rowsByQuarter = data;
            this.renderChart();
        }
        if (error) this.error = error;
    }

    @wire(getStageProgressByWeek)
    wiredWeek({ data, error }) {
        if (data) {
            this.rowsByWeek = data;
            this.renderChart();
        }
        if (error) this.error = error;
    }

    get rows() {
        return this.isWeekView ? this.rowsByWeek : this.rowsByQuarter;
    }

    // Re-render when the parent toggles the metric prop. LWC reactive
    // properties don't trigger renderedCallback automatically when the prop
    // is consumed only inside renderChart; explicit re-render covers it.
    renderedCallback() {
        if (!this.chartJsLoaded) {
            this.chartJsLoaded = true;
            loadScript(this, ChartJs)
                .then(() => this.renderChart())
                .catch(err => {
                    this.chartJsLoaded = false;
                    this.error = err;
                });
            return;
        }
        if (this._lastMetric !== this.metric || this._lastGrouping !== this.grouping) {
            this._lastMetric = this.metric;
            this._lastGrouping = this.grouping;
            this.renderChart();
        }
    }

    renderChart() {
        if (!window.Chart || !this.rows || !this.rows.length) return;
        const canvas = this.template.querySelector('canvas.pg-chart');
        if (!canvas) return;

        if (this.chart) {
            this.chart.destroy();
        }

        const isAmount = this.metric === 'amount';
        const labels = this.rows.map(r => r.fiscalLabel);
        const nb   = this.rows.map(r => (isAmount ? r.nbAmount   : r.nbCount)   || 0);
        const exp  = this.rows.map(r => (isAmount ? r.expAmount  : r.expCount)  || 0);
        const goal = this.rows.map(r => (isAmount ? r.amountGoal : r.goal)      || 0);
        const showGoal = goal.some(v => v > 0);
        const fmtTick = isAmount
            ? (v) => v >= 1_000_000 ? `$${(v / 1_000_000).toFixed(1)}M`
                  : v >= 1_000     ? `$${(v / 1_000).toFixed(0)}K`
                                   : `$${v}`
            : (v) => v;

        const ctx = canvas.getContext('2d');
        const h = canvas.height || 260;
        const nbGradient = ctx.createLinearGradient(0, 0, 0, h);
        nbGradient.addColorStop(0, '#0ea5e9');
        nbGradient.addColorStop(1, '#082f49');
        const expGradient = ctx.createLinearGradient(0, 0, 0, h);
        expGradient.addColorStop(0, '#f43f5e');
        expGradient.addColorStop(1, '#500724');

        const nbLabel  = isAmount ? 'AE NB Stage 2+ ($)'  : 'AE NB Stage 2+ Count';
        const expLabel = isAmount ? 'AE Exp Stage 2+ ($)' : 'AE Exp Stage 2+ Count';
        const goalLabel = isAmount ? 'AE Stage 2+ Amount Goal' : 'AE Qualified Stage 2+ Goal';

        const datasets = [
            {
                type: 'bar',
                label: nbLabel,
                backgroundColor: nbGradient,
                borderRadius: 4,
                borderSkipped: false,
                data: nb,
                stack: 'stage2plus'
            },
            {
                type: 'bar',
                label: expLabel,
                backgroundColor: expGradient,
                borderRadius: 4,
                borderSkipped: false,
                data: exp,
                stack: 'stage2plus'
            }
        ];
        if (showGoal) {
            datasets.unshift({
                type: 'line',
                label: goalLabel,
                borderColor: '#0f172a',
                backgroundColor: 'transparent',
                borderDash: [4, 4],
                tension: 0.2,
                pointRadius: 3,
                pointBackgroundColor: '#0f172a',
                data: goal
            });
        }

        // Custom plugin: draw stack totals above each bar so users don't
        // have to hover. Captures fmtTick + bar-dataset indices via closure.
        const barDatasetIndices = datasets
            .map((d, i) => d.type === 'bar' ? i : -1)
            .filter(i => i >= 0);
        const totalLabelsPlugin = {
            id: 'pgStackTotals',
            afterDatasetsDraw(chart) {
                if (!barDatasetIndices.length) return;
                const ctx = chart.ctx;
                const lastIdx = barDatasetIndices[barDatasetIndices.length - 1];
                const meta = chart.getDatasetMeta(lastIdx);
                if (!meta || !meta.data) return;
                ctx.save();
                ctx.font = '600 11px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
                ctx.fillStyle = '#0f172a';
                ctx.textAlign = 'center';
                ctx.textBaseline = 'bottom';
                for (let i = 0; i < meta.data.length; i++) {
                    const elem = meta.data[i];
                    if (!elem) continue;
                    let total = 0;
                    for (const idx of barDatasetIndices) {
                        const v = chart.data.datasets[idx].data[i];
                        total += Number(v) || 0;
                    }
                    if (total <= 0) continue;
                    ctx.fillText(fmtTick(total), elem.x, elem.y - 4);
                }
                ctx.restore();
            }
        };

        this.chart = new window.Chart(canvas.getContext('2d'), {
            data: { labels, datasets },
            plugins: [totalLabelsPlugin],
            options: {
                responsive: true,
                maintainAspectRatio: false,
                layout: { padding: { top: 22 } },
                plugins: {
                    legend: { labels: { color: '#475569' } },
                    tooltip: {
                        mode: 'index',
                        intersect: false,
                        callbacks: {
                            label: (ctx) => `${ctx.dataset.label}: ${fmtTick(ctx.parsed.y)}`
                        }
                    }
                },
                scales: {
                    x: {
                        stacked: true,
                        ticks: { color: '#475569' },
                        grid: { color: 'rgba(15,23,42,0.08)' }
                    },
                    y: {
                        stacked: true,
                        beginAtZero: true,
                        ticks: { color: '#475569', callback: fmtTick },
                        grid: { color: 'rgba(15,23,42,0.08)' }
                    }
                }
            }
        });
    }

    disconnectedCallback() {
        if (this.chart) this.chart.destroy();
    }
}
