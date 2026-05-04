import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getManagerTeamData from '@salesforce/apex/PipeGenController.getManagerTeamData';
import saveManagerNote    from '@salesforce/apex/PipeGenController.saveManagerNote';
import setAtRiskFlag      from '@salesforce/apex/PipeGenController.setAtRiskFlag';

const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
const CURR       = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });

export default class PipeGenManagerDashboard extends LightningElement {

    @track reps         = [];
    @track summary      = {};
    @track isLoading    = true;
    @track errorMessage = null;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading    = true;
        this.errorMessage = null;
        try {
            const raw  = await getManagerTeamData();
            this.reps    = (raw.reps || []).map(r => this.enrichRep(r));
            this.summary = this.buildSummary(raw.teamSummary || {});
        } catch (e) {
            this.errorMessage = e.body?.message || 'Failed to load team data.';
        } finally {
            this.isLoading = false;
        }
    }

    enrichRep(rep) {
        const target = rep.pipelineTarget || 0;
        const actual = rep.pipelineActual || 0;
        const attPct = target > 0 ? Math.min(100, Math.round((actual / target) * 100)) : 0;
        const isExpanded = false;
        const barClass = attPct >= 100 ? 'att-bar-fill att-bar--won'
                       : attPct >=  60 ? 'att-bar-fill att-bar--good'
                       : attPct >=  30 ? 'att-bar-fill att-bar--warn'
                       :                  'att-bar-fill att-bar--low';

        const lwCommits = (rep.lastWeekCommits || []).map(c => this.enrichCommit(c));
        const lwTotal     = lwCommits.length;
        const lwCompleted = lwCommits.filter(c => c.Completion_Status__c === 'Completed').length;

        return {
            ...rep,
            isExpanded,
            chevronIcon:          'utility:chevronright',
            expandLabel:          'View Commits',
            repCardClass:         this.repCardClass(rep, isExpanded),
            twCompletionClass:    this.twClass(rep.thisWeekCompleted, rep.thisWeekTotal),
            lwCompletionClass:    this.twClass(lwCompleted, lwTotal),
            lwCompleted,
            lwTotal,
            hasCommits:           (rep.thisWeekCommits || []).length > 0,
            hasLastWeekCommits:   lwCommits.length > 0,
            thisWeekCommits:      (rep.thisWeekCommits || []).map(c => this.enrichCommit(c)),
            lastWeekCommits:      lwCommits,
            attainmentPct:        attPct,
            attainmentBarStyle:   `width: ${attPct}%`,
            attainmentBarClass:   barClass,
            pipelineActualFmt:    CURR.format(actual),
            pipelineTargetFmt:    CURR.format(target),
            weeksRemaining:       rep.weeksRemaining || 0,
            lwOppsCreated:        rep.lwOppsCreated      || 0,
            qtdOppsCreated:       rep.qtdOppsCreated     || 0,
            lwOppsToDiscovery:    rep.lwOppsToDiscovery  || 0,
            qtdOppsToDiscovery:   rep.qtdOppsToDiscovery || 0
        };
    }

    enrichCommit(c) {
        const status    = c.Completion_Status__c || 'Not Started';
        const actual    = c.Actual_Count__c    || 0;
        const committed = c.Committed_Count__c || 1;
        const pending   = c.Manager_Note__c    || '';
        return {
            ...c,
            progressLabel:     `${actual} / ${committed}`,
            pendingNote:       pending,
            noteDirty:         false,
            isSavingNote:      false,
            isSavingFlag:      false,
            statusDotClass:    status === 'Completed' ? 'mgr-dot mgr-dot--complete'
                             : status === 'Partial'   ? 'mgr-dot mgr-dot--partial'
                             :                          'mgr-dot mgr-dot--pending',
            atRiskLabel:       c.At_Risk__c ? 'Remove Flag' : 'Flag At Risk',
            atRiskVariant:     c.At_Risk__c ? 'destructive-text' : 'neutral',
            atRiskIcon:        c.At_Risk__c ? 'utility:warning' : 'utility:flag',
            mgr_commitRowClass: `mgr-commit-row slds-p-around_small slds-m-bottom_xx-small${c.At_Risk__c ? ' mgr-commit-row--atrisk' : ''}`
        };
    }

    buildSummary(ts) {
        const total = ts.totalCommits || 0;
        const done  = ts.completedCommits || 0;
        const rate  = total > 0 ? Math.round((done / total) * 100) : 0;
        return {
            ...ts,
            completionRateLabel: `${done}/${total} (${rate}%)`,
            completionRateValue: rate
        };
    }

    repCardClass(rep, isExpanded) {
        let cls = 'rep-card';
        if (rep.hasRisk)   cls += ' rep-card--risk';
        if (isExpanded)    cls += ' rep-card--expanded';
        return cls;
    }

    twClass(completed, total) {
        if (!total) return 'stat-value stat-none';
        return completed === total ? 'stat-value stat-done' : 'stat-value stat-partial';
    }

    // ─── Computed ─────────────────────────────────────────────────────────────

    get isReady()  { return !this.isLoading && !this.errorMessage; }
    get hasError() { return !!this.errorMessage; }
    get hasReps()  { return this.reps.length > 0; }

    get weekLabel() {
        const today = new Date();
        const dow   = today.getDay();
        const mon   = new Date(today);
        mon.setDate(today.getDate() - ((dow + 6) % 7));
        return 'Week of ' + SHORT_DATE.format(mon);
    }

    get completionRateClass() {
        const rate = this.summary.completionRateValue || 0;
        return rate >= 75 ? 'summary-value summary-value--good'
             : rate >= 40 ? 'summary-value summary-value--warn'
             :               'summary-value summary-value--bad';
    }

    get noCommitsClass() {
        return (this.summary.repsWithNoCommits || 0) > 0
            ? 'summary-value summary-value--bad'
            : 'summary-value summary-value--good';
    }

    // ─── Handlers ─────────────────────────────────────────────────────────────

    handleRepExpand(e) {
        const id = e.currentTarget.dataset.id;
        this.reps = this.reps.map(r => {
            if (r.repId !== id) return r;
            const expanded = !r.isExpanded;
            return {
                ...r,
                isExpanded:   expanded,
                chevronIcon:  expanded ? 'utility:chevrondown' : 'utility:chevronright',
                expandLabel:  expanded ? 'Hide Commits' : 'View Commits',
                repCardClass: this.repCardClass(r, expanded)
            };
        });
    }

    handleNoteChange(e) {
        const id    = e.currentTarget.dataset.id;
        const value = e.detail.value;
        this.reps = this.reps.map(r => ({
            ...r,
            thisWeekCommits: r.thisWeekCommits.map(c => {
                if (c.Id !== id) return c;
                return { ...c, pendingNote: value, noteDirty: value !== (c.Manager_Note__c || '') };
            })
        }));
    }

    async handleNoteSave(e) {
        const id = e.currentTarget.dataset.id;
        this.setCommitProp(id, { isSavingNote: true });
        try {
            await saveManagerNote({ commitId: id, note: this.getNoteValue(id) });
            this.reps = this.reps.map(r => ({
                ...r,
                thisWeekCommits: r.thisWeekCommits.map(c => {
                    if (c.Id !== id) return c;
                    return { ...c, Manager_Note__c: c.pendingNote, noteDirty: false, isSavingNote: false };
                })
            }));
            this.toast('Note Saved', '', 'success');
        } catch (err) {
            this.setCommitProp(id, { isSavingNote: false });
            this.toast('Error', 'Could not save note.', 'error');
        }
    }

    async handleAtRiskToggle(e) {
        const id      = e.currentTarget.dataset.id;
        const current = e.currentTarget.dataset.current === 'true';
        const newVal  = !current;
        this.setCommitProp(id, { isSavingFlag: true });
        try {
            await setAtRiskFlag({ commitId: id, atRisk: newVal });
            this.reps = this.reps.map(r => ({
                ...r,
                thisWeekCommits: r.thisWeekCommits.map(c => {
                    if (c.Id !== id) return c;
                    return {
                        ...c,
                        At_Risk__c:         newVal,
                        isSavingFlag:       false,
                        atRiskLabel:        newVal ? 'Remove Flag' : 'Flag At Risk',
                        atRiskVariant:      newVal ? 'destructive-text' : 'neutral',
                        atRiskIcon:         newVal ? 'utility:warning' : 'utility:flag',
                        mgr_commitRowClass: `mgr-commit-row slds-p-around_small slds-m-bottom_xx-small${newVal ? ' mgr-commit-row--atrisk' : ''}`
                    };
                }),
                hasRisk: r.thisWeekCommits.some(c => c.Id === id ? newVal : c.At_Risk__c) || r.riskReasons.length > 0
            }));
        } catch (err) {
            this.setCommitProp(id, { isSavingFlag: false });
            this.toast('Error', 'Could not update flag.', 'error');
        }
    }

    // ─── Utilities ────────────────────────────────────────────────────────────

    setCommitProp(commitId, props) {
        this.reps = this.reps.map(r => ({
            ...r,
            thisWeekCommits: r.thisWeekCommits.map(c =>
                c.Id === commitId ? { ...c, ...props } : c
            )
        }));
    }

    getNoteValue(commitId) {
        for (const r of this.reps)
            for (const c of r.thisWeekCommits)
                if (c.Id === commitId) return c.pendingNote;
        return '';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
