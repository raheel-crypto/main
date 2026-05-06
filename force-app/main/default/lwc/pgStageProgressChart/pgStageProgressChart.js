import { LightningElement, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';
import getStageProgressByQuarter from '@salesforce/apex/PGInsightsController.getStageProgressByQuarter';

export default class PgStageProgressChart extends LightningElement {
    chart;
    chartJsLoaded = false;
    rows = [];
    error;

    @wire(getStageProgressByQuarter, { numQuarters: 6 })
    wiredRows({ data, error }) {
        if (data) {
            this.rows = data;
            this.renderChart();
        }
        if (error) {
            this.error = error;
        }
    }

    renderedCallback() {
        if (this.chartJsLoaded) return;
        this.chartJsLoaded = true;
        loadScript(this, ChartJs)
            .then(() => this.renderChart())
            .catch(err => {
                this.chartJsLoaded = false;
                this.error = err;
            });
    }

    renderChart() {
        if (!window.Chart || !this.rows || !this.rows.length) return;
        const canvas = this.template.querySelector('canvas.pg-chart');
        if (!canvas) return;

        if (this.chart) {
            this.chart.destroy();
        }

        const labels = this.rows.map(r => r.fiscalLabel);
        const nb = this.rows.map(r => r.nbCount || 0);
        const exp = this.rows.map(r => r.expCount || 0);
        const goal = this.rows.map(r => r.goal || 0);
        const showGoal = goal.some(v => v > 0);

        const ctx = canvas.getContext('2d');
        const h = canvas.height || 260;
        const nbGradient = ctx.createLinearGradient(0, 0, 0, h);
        nbGradient.addColorStop(0, '#0ea5e9');
        nbGradient.addColorStop(1, '#082f49');
        const expGradient = ctx.createLinearGradient(0, 0, 0, h);
        expGradient.addColorStop(0, '#f43f5e');
        expGradient.addColorStop(1, '#500724');

        const datasets = [
            {
                type: 'bar',
                label: 'AE NB Stage 2+ Count',
                backgroundColor: nbGradient,
                borderRadius: 4,
                borderSkipped: false,
                data: nb,
                stack: 'stage2plus'
            },
            {
                type: 'bar',
                label: 'AE Exp Stage 2+ Count',
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
                label: 'AE Qualified Stage 2+ Goal',
                borderColor: '#0f172a',
                backgroundColor: 'transparent',
                borderDash: [4, 4],
                tension: 0.2,
                pointRadius: 3,
                pointBackgroundColor: '#0f172a',
                data: goal
            });
        }

        this.chart = new window.Chart(canvas.getContext('2d'), {
            data: { labels, datasets },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { labels: { color: '#475569' } },
                    tooltip: { mode: 'index', intersect: false }
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
                        ticks: { color: '#475569' },
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
