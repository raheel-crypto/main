import { LightningElement, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';
import getStageProgressByQuarter from '@salesforce/apex/PGInsightsController.getStageProgressByQuarter';

export default class PgStageProgressChart extends LightningElement {
    chart;
    chartJsLoaded = false;
    rows = [];
    error;

    @wire(getStageProgressByQuarter, { numQuarters: 8 })
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

        const datasets = [
            {
                type: 'bar',
                label: 'AE NB S1 Count',
                backgroundColor: '#06b6d4',
                data: nb,
                stack: 'sqo'
            },
            {
                type: 'bar',
                label: 'AE Exp S1 Count',
                backgroundColor: '#ec4899',
                data: exp,
                stack: 'sqo'
            }
        ];
        if (showGoal) {
            datasets.unshift({
                type: 'line',
                label: 'AE Qualified S1 Goal',
                borderColor: '#fff',
                backgroundColor: 'transparent',
                tension: 0.2,
                pointRadius: 3,
                data: goal
            });
        }

        this.chart = new window.Chart(canvas.getContext('2d'), {
            data: { labels, datasets },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { labels: { color: '#cbd5e1' } },
                    tooltip: { mode: 'index', intersect: false }
                },
                scales: {
                    x: {
                        stacked: true,
                        ticks: { color: '#cbd5e1' },
                        grid: { color: 'rgba(255,255,255,0.05)' }
                    },
                    y: {
                        stacked: true,
                        beginAtZero: true,
                        ticks: { color: '#cbd5e1' },
                        grid: { color: 'rgba(255,255,255,0.05)' }
                    }
                }
            }
        });
    }

    disconnectedCallback() {
        if (this.chart) this.chart.destroy();
    }
}
