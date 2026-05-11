import { LightningElement, api, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';
import getBookedTrendByWeek    from '@salesforce/apex/PGGtmInsightsController.getBookedTrendByWeek';
import getBookedTrendByQuarter from '@salesforce/apex/PGGtmInsightsController.getBookedTrendByQuarter';

export default class PgGtmTrendChart extends LightningElement {
    @api metric = 'count';

    grouping = 'week';
    chart;
    chartJsLoaded = false;
    rowsByWeek = [];
    rowsByQuarter = [];
    error;

    get isWeekView()    { return this.grouping === 'week'; }
    get isAmount()      { return this.metric === 'amount'; }
    get weekToggleClass()    { return 'pg-mini-toggle__btn' + (this.isWeekView  ? ' pg-mini-toggle__btn--active' : ''); }
    get quarterToggleClass() { return 'pg-mini-toggle__btn' + (!this.isWeekView ? ' pg-mini-toggle__btn--active' : ''); }

    handleSelectWeek()    { this.grouping = 'week';    }
    handleSelectQuarter() { this.grouping = 'quarter'; }

    get title() {
        const metricLabel = this.isAmount ? 'Pipeline ($)' : 'Opps Booked';
        return this.isWeekView
            ? `${metricLabel} | Per Week (this Q)`
            : `${metricLabel} | Last 6 Quarters`;
    }

    get rows() {
        return this.isWeekView ? this.rowsByWeek : this.rowsByQuarter;
    }

    @wire(getBookedTrendByWeek)
    wiredWeek({ data, error }) {
        if (data) { this.rowsByWeek = data; this.renderChart(); }
        if (error) this.error = error;
    }

    @wire(getBookedTrendByQuarter, { numQuarters: 6 })
    wiredQuarter({ data, error }) {
        if (data) { this.rowsByQuarter = data; this.renderChart(); }
        if (error) this.error = error;
    }

    renderedCallback() {
        if (!this.chartJsLoaded) {
            this.chartJsLoaded = true;
            loadScript(this, ChartJs)
                .then(() => this.renderChart())
                .catch(err => { this.chartJsLoaded = false; this.error = err; });
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
        if (this.chart) this.chart.destroy();

        const isAmt = this.isAmount;
        const labels = this.rows.map(r => r.label);
        const qualified = this.rows.map(r => (isAmt ? r.qualifiedAmount : r.qualifiedCount) || 0);
        const notYet = this.rows.map((r, i) => {
            const total = (isAmt ? r.bookedAmount : r.bookedCount) || 0;
            return Math.max(0, total - qualified[i]);
        });

        const ctx = canvas.getContext('2d');
        const h = canvas.height || 260;
        const qualifiedGrad = ctx.createLinearGradient(0, 0, 0, h);
        qualifiedGrad.addColorStop(0, '#22d3ee');
        qualifiedGrad.addColorStop(1, '#0e7490');
        const notYetGrad = ctx.createLinearGradient(0, 0, 0, h);
        notYetGrad.addColorStop(0, '#a78bfa');
        notYetGrad.addColorStop(1, '#4c1d95');

        const fmtTick = isAmt
            ? (v) => v >= 1_000_000 ? `$${(v / 1_000_000).toFixed(1)}M`
                  : v >= 1_000     ? `$${(v / 1_000).toFixed(0)}K`
                                   : `$${v}`
            : (v) => v;

        const datasets = [
            {
                type: 'bar',
                label: 'Qualified (Stage 2+)',
                backgroundColor: qualifiedGrad,
                borderRadius: 4,
                borderSkipped: false,
                data: qualified,
                stack: 'booked'
            },
            {
                type: 'bar',
                label: 'Booked, not yet qualified',
                backgroundColor: notYetGrad,
                borderRadius: 4,
                borderSkipped: false,
                data: notYet,
                stack: 'booked'
            }
        ];

        const totalLabelsPlugin = {
            id: 'pgStackTotals',
            afterDatasetsDraw(chart) {
                const meta = chart.getDatasetMeta(datasets.length - 1);
                if (!meta || !meta.data) return;
                const ctx2 = chart.ctx;
                ctx2.save();
                ctx2.font = '600 11px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
                ctx2.fillStyle = '#0f172a';
                ctx2.textAlign = 'center';
                ctx2.textBaseline = 'bottom';
                for (let i = 0; i < meta.data.length; i++) {
                    const elem = meta.data[i];
                    if (!elem) continue;
                    const total = qualified[i] + notYet[i];
                    if (total <= 0) continue;
                    ctx2.fillText(fmtTick(total), elem.x, elem.y - 4);
                }
                ctx2.restore();
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
                        callbacks: { label: (c) => `${c.dataset.label}: ${fmtTick(c.parsed.y)}` }
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
