import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getVPDashboardData from '@salesforce/apex/PipeGenController.getVPDashboardData';
import saveManagerNote    from '@salesforce/apex/PipeGenController.saveManagerNote';
import setAtRiskFlag      from '@salesforce/apex/PipeGenController.setAtRiskFlag';

const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
const CURR       = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });

export default class PipeGenVPDashboard extends LightningElement {

    @track managers     = [];
    @track reps         = [];
    @track summary      = {};
    @track isVP         = false;
    @track isLoading    = true;
    @track errorMessage = null;
    @track modal        = { isOpen: false, type: null, managerId: null, repId: null };

    connectedCallback() { this.loadData(); }

    async loadData() {
        this.isLoading = true; this.errorMessage = null;
        try {
            const raw    = await getVPDashboardData();
            this.isVP    = raw.isVP;
            this.summary = this.buildSummary(raw.teamSummary || {});
            if (raw.isVP) {
                this.managers = (raw.managers || []).map(m => this.enrichManager(m));
                this.reps     = [];
            } else {
                this.reps     = (raw.reps || []).map(r => this.enrichRep(r));
                this.managers = [];
            }
        } catch (e) {
            this.errorMessage = e.body?.message || 'Failed to load dashboard data.';
        } finally {
            this.isLoading = false;
        }
    }

    // ── Enrichment ─────────────────────────────────────────────────────────────

    enrichManager(mgr) {
        const target  = mgr.pipelineTarget || 0;
        const actual  = mgr.pipelineActual || 0;
        const attPct  = target > 0 ? Math.min(100, Math.round((actual / target) * 100)) : 0;
        const barClass = attPct >= 100 ? 'att-bar-fill att-bar--won'
                       : attPct >=  60 ? 'att-bar-fill att-bar--good'
                       : attPct >=  30 ? 'att-bar-fill att-bar--warn'
                       :                  'att-bar-fill att-bar--low';
        return {
            ...mgr,
            mgrCardClass:       this.mgrCardClass(mgr),
            attainmentPct:      attPct,
            attainmentBarStyle: `width: ${attPct}%`,
            attainmentBarClass: barClass,
            pipelineActualFmt:  CURR.format(actual),
            pipelineTargetFmt:  CURR.format(target),
            twCompletionClass:  this.completionClass(mgr.thisWeekCompleted, mgr.thisWeekTotal),
            lwCompletionClass:  this.completionClass(mgr.lwCompleted, mgr.lwTotal),
            reps: (mgr.reps || []).map(r => this.enrichRep(r))
        };
    }

    enrichRep(rep) {
        const target = rep.pipelineTarget || 0;
        const actual = rep.pipelineActual || 0;
        const attPct = target > 0 ? Math.min(100, Math.round((actual / target) * 100)) : 0;
        const barClass = attPct >= 100 ? 'att-bar-fill att-bar--won'
                       : attPct >=  60 ? 'att-bar-fill att-bar--good'
                       : attPct >=  30 ? 'att-bar-fill att-bar--warn'
                       :                  'att-bar-fill att-bar--low';
        const lwCommits   = (rep.lastWeekCommits || []).map(c => this.enrichCommit(c));
        const lwTotal     = lwCommits.length;
        const lwCompleted = lwCommits.filter(c => c.Completion_Status__c === 'Completed').length;
        return {
            ...rep,
            repCardClass:       this.repCardClass(rep),
            twCompletionClass:  this.completionClass(rep.thisWeekCompleted, rep.thisWeekTotal),
            lwCompletionClass:  this.completionClass(lwCompleted, lwTotal),
            lwCompleted, lwTotal,
            hasCommits:         (rep.thisWeekCommits || []).length > 0,
            hasLastWeekCommits: lwCommits.length > 0,
            thisWeekCommits:    (rep.thisWeekCommits || []).map(c => this.enrichCommit(c)),
            lastWeekCommits:    lwCommits,
            attainmentPct:      attPct,
            attainmentBarStyle: `width: ${attPct}%`,
            attainmentBarClass: barClass,
            pipelineActualFmt:  CURR.format(actual),
            pipelineTargetFmt:  CURR.format(target),
            weeksRemaining:     rep.weeksRemaining      || 0,
            lwOppsCreated:      rep.lwOppsCreated       || 0,
            qtdOppsCreated:     rep.qtdOppsCreated      || 0,
            lwOppsToDiscovery:  rep.lwOppsToDiscovery   || 0,
            qtdOppsToDiscovery: rep.qtdOppsToDiscovery  || 0
        };
    }

    enrichCommit(c) {
        const status    = c.Completion_Status__c || 'Not Started';
        const actual    = c.Actual_Count__c      || 0;
        const committed = c.Committed_Count__c   || 1;
        return {
            ...c,
            progressLabel:      `${actual} / ${committed}`,
            pendingNote:        c.Manager_Note__c || '',
            noteDirty:          false,
            isSavingNote:       false,
            isSavingFlag:       false,
            statusDotClass:     status === 'Completed' ? 'mgr-dot mgr-dot--complete'
                              : status === 'Partial'   ? 'mgr-dot mgr-dot--partial'
                              :                          'mgr-dot mgr-dot--pending',
            atRiskLabel:        c.At_Risk__c ? 'Remove Flag' : 'Flag At Risk',
            atRiskVariant:      c.At_Risk__c ? 'destructive-text' : 'neutral',
            atRiskIcon:         c.At_Risk__c ? 'utility:warning' : 'utility:flag',
            mgr_commitRowClass: `mgr-commit-row slds-p-around_small slds-m-bottom_xx-small${c.At_Risk__c ? ' mgr-commit-row--atrisk' : ''}`
        };
    }

    buildSummary(ts) {
        const total = ts.totalCommits || 0;
        const done  = ts.completedCommits || 0;
        const rate  = total > 0 ? Math.round((done / total) * 100) : 0;
        return { ...ts, completionRateLabel: `${done}/${total} (${rate}%)`, completionRateValue: rate };
    }

    mgrCardClass(mgr) {
        return 'mgr-card' + (mgr.hasRisk ? ' mgr-card--risk' : '');
    }

    repCardClass(rep) {
        return 'rep-card' + (rep.hasRisk ? ' rep-card--risk' : '');
    }

    completionClass(completed, total) {
        if (!total) return 'stat-value stat-none';
        return completed === total ? 'stat-value stat-done' : 'stat-value stat-partial';
    }

    // ── Computed ───────────────────────────────────────────────────────────────

    get isReady()     { return !this.isLoading && !this.errorMessage; }
    get hasError()    { return !!this.errorMessage; }
    get hasManagers() { return this.managers.length > 0; }
    get hasReps()     { return this.reps.length > 0; }

    get weekLabel() {
        const today = new Date();
        const mon   = new Date(today);
        mon.setDate(today.getDate() - ((today.getDay() + 6) % 7));
        return 'Week of ' + SHORT_DATE.format(mon);
    }

    get completionRateClass() {
        const r = this.summary.completionRateValue || 0;
        return r >= 75 ? 'summary-value summary-value--good'
             : r >= 40 ? 'summary-value summary-value--warn'
             :            'summary-value summary-value--bad';
    }

    get noCommitsClass() {
        return (this.summary.repsWithNoCommits || 0) > 0
            ? 'summary-value summary-value--bad'
            : 'summary-value summary-value--good';
    }

    // ── Modal computed ─────────────────────────────────────────────────────────

    get isModalTeam()    { return this.modal.type === 'team'; }
    get isModalCommits() { return this.modal.type === 'commits'; }

    get canGoBack() {
        return this.modal.type === 'commits' && !!this.modal.managerId && this.isVP;
    }

    get modalManager() {
        return this.managers.find(m => m.managerId === this.modal.managerId);
    }

    get modalRep() {
        const { repId, managerId } = this.modal;
        if (managerId) {
            const mgr = this.managers.find(m => m.managerId === managerId);
            return mgr?.reps.find(r => r.repId === repId);
        }
        return this.reps.find(r => r.repId === repId);
    }

    get modalTitle() {
        if (this.isModalTeam)    return `${this.modalManager?.managerName || ‘’}’s Team`;
        if (this.isModalCommits) return `${this.modalRep?.repName || ‘’} — Commits`;
        return ‘’;
    }

    // ── Modal handlers ─────────────────────────────────────────────────────────

    handleViewTeam(e) {
        const id = e.currentTarget.dataset.id;
        this.modal = { isOpen: true, type: 'team', managerId: id, repId: null };
    }

    handleViewCommits(e) {
        const repId = e.currentTarget.dataset.repid;
        const mgrId = e.currentTarget.dataset.mgrid || null;
        this.modal  = { isOpen: true, type: 'commits', managerId: mgrId, repId };
    }

    handleModalBack() {
        this.modal = { ...this.modal, type: 'team', repId: null };
    }

    closeModal() {
        this.modal = { isOpen: false, type: null, managerId: null, repId: null };
    }

    handleBackdropClick(e) {
        if (e.target === e.currentTarget) this.closeModal();
    }

    // ── Commit handlers ────────────────────────────────────────────────────────

    handleNoteChange(e) {
        const commitId = e.target.dataset.id;
        const mgrId    = e.target.dataset.mgrid;
        const value    = e.target.value;
        this._updateCommit(commitId, mgrId, c => ({
            ...c, pendingNote: value, noteDirty: value !== (c.Manager_Note__c || '')
        }));
    }

    async handleNoteSave(e) {
        const commitId = e.currentTarget.dataset.id;
        const mgrId    = e.currentTarget.dataset.mgrid;
        this._updateCommit(commitId, mgrId, c => ({ ...c, isSavingNote: true }));
        try {
            const note = this._getNoteValue(commitId, mgrId);
            await saveManagerNote({ commitId, note });
            this._updateCommit(commitId, mgrId, c => ({
                ...c, Manager_Note__c: c.pendingNote, noteDirty: false, isSavingNote: false
            }));
            this.toast('Note Saved', '', 'success');
        } catch {
            this._updateCommit(commitId, mgrId, c => ({ ...c, isSavingNote: false }));
            this.toast('Error', 'Could not save note.', 'error');
        }
    }

    async handleAtRiskToggle(e) {
        const commitId = e.currentTarget.dataset.id;
        const mgrId    = e.currentTarget.dataset.mgrid;
        const current  = e.currentTarget.dataset.current === 'true';
        const newVal   = !current;
        this._updateCommit(commitId, mgrId, c => ({ ...c, isSavingFlag: true }));
        try {
            await setAtRiskFlag({ commitId, atRisk: newVal });
            this._updateCommit(commitId, mgrId, c => ({
                ...c,
                At_Risk__c:         newVal,
                isSavingFlag:       false,
                atRiskLabel:        newVal ? 'Remove Flag' : 'Flag At Risk',
                atRiskVariant:      newVal ? 'destructive-text' : 'neutral',
                atRiskIcon:         newVal ? 'utility:warning' : 'utility:flag',
                mgr_commitRowClass: `mgr-commit-row slds-p-around_small slds-m-bottom_xx-small${newVal ? ' mgr-commit-row--atrisk' : ''}`
            }));
        } catch {
            this._updateCommit(commitId, mgrId, c => ({ ...c, isSavingFlag: false }));
            this.toast('Error', 'Could not update flag.', 'error');
        }
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    _updateCommit(commitId, mgrId, fn) {
        const applyToList = list => list.map(c => c.Id === commitId ? fn(c) : c);
        if (mgrId) {
            this.managers = this.managers.map(m => {
                if (m.managerId !== mgrId) return m;
                return {
                    ...m,
                    reps: m.reps.map(r => ({
                        ...r,
                        thisWeekCommits: applyToList(r.thisWeekCommits)
                    }))
                };
            });
        } else {
            this.reps = this.reps.map(r => ({
                ...r,
                thisWeekCommits: applyToList(r.thisWeekCommits)
            }));
        }
    }

    _getNoteValue(commitId, mgrId) {
        const repList = mgrId
            ? (this.managers.find(m => m.managerId === mgrId)?.reps || [])
            : this.reps;
        for (const r of repList)
            for (const c of r.thisWeekCommits)
                if (c.Id === commitId) return c.pendingNote;
        return '';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
