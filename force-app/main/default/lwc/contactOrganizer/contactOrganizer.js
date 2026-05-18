import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import loadOrganizer from '@salesforce/apex/ContactOrganizerController.loadOrganizer';
import saveAssignments from '@salesforce/apex/ContactOrganizerController.saveAssignments';
import searchAccountContacts from '@salesforce/apex/ContactOrganizerController.searchAccountContacts';

const ROLES = [
    { key: 'C-Suite/Executive', label: 'C-Suite / Executive' },
    { key: 'Technology/Ops', label: 'Technology / Ops' },
    { key: 'Senior User', label: 'Senior User' },
    { key: 'Junior User', label: 'Junior User' }
];

const SEARCH_DEBOUNCE_MS = 250;

const MS_PER_DAY = 86400000;

function relativeDays(dateString) {
    if (!dateString) return null;
    const then = new Date(dateString);
    if (isNaN(then.getTime())) return null;
    const now = new Date();
    const todayUtc = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
    const thenUtc = Date.UTC(then.getUTCFullYear(), then.getUTCMonth(), then.getUTCDate());
    return Math.floor((todayUtc - thenUtc) / MS_PER_DAY);
}

function formatRelative(days) {
    if (days == null) return '';
    if (days <= 0) return 'today';
    if (days === 1) return '1d ago';
    if (days < 7) return `${days}d ago`;
    if (days < 30) return `${Math.floor(days / 7)}w ago`;
    if (days < 365) return `${Math.floor(days / 30)}mo ago`;
    return `${Math.floor(days / 365)}y ago`;
}

function buildActivityBadge(activity) {
    const total = (activity && activity.total) || 0;
    if (!total) {
        return {
            hasActivity: false,
            cssClass: 'activity-pill activity-pill--cold',
            label: 'No engagement',
            countLabel: '0',
            relativeLabel: '',
            tooltip: 'No tracked activity'
        };
    }
    const days = relativeDays(activity.lastActivityDate);
    let freshness = 'cold';
    if (days != null) {
        if (days < 7) freshness = 'hot';
        else if (days < 30) freshness = 'warm';
    }
    const relative = formatRelative(days);
    const parts = [];
    if (activity.emails) parts.push(`${activity.emails} email${activity.emails === 1 ? '' : 's'}`);
    if (activity.meetings) parts.push(`${activity.meetings} meeting${activity.meetings === 1 ? '' : 's'}`);
    if (activity.gongCalls) parts.push(`${activity.gongCalls} Gong call${activity.gongCalls === 1 ? '' : 's'}`);
    if (activity.last7d) parts.push(`${activity.last7d} in last 7d`);
    const tooltip = parts.length ? parts.join(' · ') : `${total} activities`;
    return {
        hasActivity: true,
        cssClass: `activity-pill activity-pill--${freshness}`,
        countLabel: `${total}`,
        relativeLabel: relative,
        tooltip,
        label: relative ? `${total} · ${relative}` : `${total}`
    };
}

export default class ContactOrganizer extends LightningElement {
    @api recordId;

    @track assignments = {};
    @track searchResults = [];
    @track summary = {};
    accountName;
    accountId;
    totalContacts = 0;
    isLoading = true;
    isSaving = false;
    isSearching = false;
    isDirty = false;
    hasLoadedData = false;
    errorMessage;
    wiredResult;
    searchTerm = '';
    debounceHandle;
    draggedContactId;

    @wire(loadOrganizer, { opportunityId: '$recordId' })
    wiredLoad(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.hydrate(data);
            this.errorMessage = undefined;
            this.hasLoadedData = true;
            this.isLoading = false;
            this.runSearch();
        } else if (error) {
            this.errorMessage = this.extractError(error);
            this.hasLoadedData = true;
            this.isLoading = false;
        }
    }

    hydrate(data) {
        this.accountName = data.accountName;
        this.accountId = data.accountId;
        this.totalContacts = data.totalContacts || 0;
        this.summary = data.summary || {};
        const map = {};
        for (const a of data.assignments || []) {
            map[a.contactId] = {
                contactId: a.contactId,
                name: a.name,
                title: a.title,
                email: a.email,
                role: a.role,
                isChampion: !!a.isChampion,
                activity: a.activity || {}
            };
        }
        this.assignments = map;
        this.isDirty = false;
    }

    get bucketColumns() {
        return ROLES.map((r) => {
            const tiles = Object.values(this.assignments)
                .filter((a) => a.role === r.key)
                .sort((x, y) => (x.name || '').localeCompare(y.name || ''))
                .map((a) => {
                    const badge = buildActivityBadge(a.activity);
                    return {
                        contactId: a.contactId,
                        name: a.name,
                        title: a.title,
                        email: a.email,
                        isChampion: a.isChampion,
                        cssClass: a.isChampion
                            ? 'contact-tile contact-tile--bucket contact-tile--champion'
                            : 'contact-tile contact-tile--bucket',
                        championIcon: 'utility:favorite',
                        championVariant: a.isChampion ? 'brand' : 'border-filled',
                        championAlt: a.isChampion ? 'Unmark Champion' : 'Mark as Champion',
                        activityBadge: badge,
                        hasActivity: badge.hasActivity,
                        showNoActivity: !badge.hasActivity
                    };
                });
            return {
                key: r.key,
                label: r.label,
                tiles,
                count: tiles.length,
                isEmpty: tiles.length === 0
            };
        });
    }

    get searchResultsToRender() {
        return this.searchResults
            .filter((c) => !this.assignments[c.id])
            .map((c) => {
                const badge = buildActivityBadge(c.activity);
                return {
                    id: c.id,
                    name: c.name,
                    title: c.title,
                    email: c.email,
                    cssClass: 'contact-tile contact-tile--search',
                    activityBadge: badge,
                    hasActivity: badge.hasActivity,
                    showNoActivity: !badge.hasActivity
                };
            });
    }

    get hasAccount() {
        return !!this.accountId;
    }

    get showError() {
        return !this.isLoading && !!this.errorMessage;
    }

    get showMainUI() {
        return !this.isLoading && this.hasLoadedData && !this.errorMessage && !!this.accountId;
    }

    get showNoAccountMessage() {
        return !this.isLoading && this.hasLoadedData && !this.errorMessage && !this.accountId;
    }

    get hasSearchResults() {
        return this.searchResultsToRender.length > 0;
    }

    get showSearchSpinner() {
        return this.isSearching;
    }

    get showSearchResults() {
        return !this.isSearching && this.hasSearchResults;
    }

    get showSearchEmpty() {
        return !this.isSearching && !this.hasSearchResults;
    }

    get searchEmptyMessage() {
        if (this.searchTerm) {
            return `No matches for "${this.searchTerm}".`;
        }
        if (this.totalContacts === 0) {
            return 'This Account has no contacts.';
        }
        return 'Start typing to search this Account’s contacts.';
    }

    get totalContactsLabel() {
        const n = (this.totalContacts || 0).toLocaleString();
        return this.totalContacts === 1 ? '1 contact on Account' : `${n} contacts on Account`;
    }

    get assignedCount() {
        return Object.keys(this.assignments).length;
    }

    get assignedCountLabel() {
        return `${this.assignedCount} mapped`;
    }

    get summaryStats() {
        const s = this.summary || {};
        const total = s.totalActivities || 0;
        const last7 = s.activitiesLast7d || 0;
        const engaged = s.engagedContacts || 0;
        const lastDays = relativeDays(s.lastActivityDate);
        const lastLabel = lastDays != null ? formatRelative(lastDays) : '—';
        return [
            { key: 'activities', label: 'Activities', value: total.toLocaleString() },
            { key: 'recent', label: 'Last 7d', value: last7.toLocaleString() },
            { key: 'engaged', label: 'Engaged', value: `${engaged.toLocaleString()} / ${this.totalContacts.toLocaleString()}` },
            { key: 'last', label: 'Last touch', value: lastLabel }
        ];
    }

    get hasSummary() {
        const s = this.summary || {};
        return (s.totalActivities || 0) > 0;
    }

    get saveDisabled() {
        return this.isSaving || !this.isDirty;
    }

    get searchPlaceholder() {
        if (this.totalContacts > 50) {
            return 'Search by name, title, or email…';
        }
        return 'Search contacts…';
    }

    handleSearchChange(event) {
        const detailValue = event.detail && event.detail.value;
        const targetValue = event.target && event.target.value;
        const next = detailValue != null ? detailValue : (targetValue != null ? targetValue : '');
        this.searchTerm = next;
        if (this.debounceHandle) {
            clearTimeout(this.debounceHandle);
        }
        this.debounceHandle = setTimeout(() => this.runSearch(), SEARCH_DEBOUNCE_MS);
    }

    async runSearch() {
        if (!this.accountId) return;
        this.isSearching = true;
        try {
            const excludeIds = Object.keys(this.assignments);
            const results = await searchAccountContacts({
                accountId: this.accountId,
                opportunityId: this.recordId,
                searchTerm: this.searchTerm,
                excludeIds
            });
            this.searchResults = results || [];
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Search failed',
                message: this.extractError(error),
                variant: 'error'
            }));
        } finally {
            this.isSearching = false;
        }
    }

    handleDragStart(event) {
        this.draggedContactId = event.currentTarget.dataset.contactId;
        event.dataTransfer.effectAllowed = 'move';
        try {
            event.dataTransfer.setData('text/plain', this.draggedContactId);
        } catch (e) {
            // some browsers throw — safe to ignore
        }
    }

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
        event.currentTarget.classList.add('drop-target');
    }

    handleDragLeave(event) {
        event.currentTarget.classList.remove('drop-target');
    }

    handleDropOnBucket(event) {
        event.preventDefault();
        event.currentTarget.classList.remove('drop-target');
        const targetRole = event.currentTarget.dataset.role;
        const contactId = this.draggedContactId || event.dataTransfer.getData('text/plain');
        this.draggedContactId = null;
        if (!contactId || !targetRole) return;
        this.assignContact(contactId, targetRole);
    }

    handleDropOnSearch(event) {
        event.preventDefault();
        event.currentTarget.classList.remove('drop-target');
        const contactId = this.draggedContactId || event.dataTransfer.getData('text/plain');
        this.draggedContactId = null;
        if (!contactId) return;
        this.unassignContact(contactId);
    }

    assignContact(contactId, role) {
        const existing = this.assignments[contactId];
        if (existing) {
            if (existing.role !== role) {
                this.assignments = {
                    ...this.assignments,
                    [contactId]: { ...existing, role }
                };
                this.isDirty = true;
            }
            return;
        }
        const fromSearch = this.searchResults.find((c) => c.id === contactId);
        if (!fromSearch) return;
        this.assignments = {
            ...this.assignments,
            [contactId]: {
                contactId,
                name: fromSearch.name,
                title: fromSearch.title,
                email: fromSearch.email,
                role,
                isChampion: false,
                activity: fromSearch.activity || {}
            }
        };
        this.isDirty = true;
    }

    unassignContact(contactId) {
        if (!this.assignments[contactId]) return;
        const next = { ...this.assignments };
        delete next[contactId];
        this.assignments = next;
        this.isDirty = true;
        this.runSearch();
    }

    handleToggleChampion(event) {
        const contactId = event.currentTarget.dataset.contactId;
        const existing = this.assignments[contactId];
        if (!existing) return;
        this.assignments = {
            ...this.assignments,
            [contactId]: { ...existing, isChampion: !existing.isChampion }
        };
        this.isDirty = true;
    }

    handleMoveMenu(event) {
        const contactId = event.currentTarget.dataset.contactId;
        const value = event.detail.value;
        if (!contactId || !value) return;
        if (value === 'UNASSIGN') {
            this.unassignContact(contactId);
        } else {
            this.assignContact(contactId, value);
        }
    }

    async handleSave() {
        this.isSaving = true;
        const inputs = Object.values(this.assignments).map((a) => ({
            contactId: a.contactId,
            role: a.role,
            isChampion: !!a.isChampion
        }));
        try {
            const result = await saveAssignments({
                opportunityId: this.recordId,
                assignmentsJson: JSON.stringify(inputs)
            });
            this.isDirty = false;
            const r = result || {};
            const changed = (r.inserted || 0) + (r.updated || 0) + (r.deleted || 0);
            const variant =
                inputs.length > 0 && changed === 0 ? 'warning' : 'success';
            const message =
                `Sent ${inputs.length} · Received ${r.received || 0} · ` +
                `Inserted ${r.inserted || 0} · Updated ${r.updated || 0} · ` +
                `Removed ${r.deleted || 0} · Skipped ${r.skipped || 0}`;
            this.dispatchEvent(new ShowToastEvent({
                title: variant === 'success' ? 'Saved' : 'No changes persisted',
                message,
                variant
            }));
            await refreshApex(this.wiredResult);
            this.runSearch();
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Save failed',
                message: this.extractError(error),
                variant: 'error'
            }));
        } finally {
            this.isSaving = false;
        }
    }

    async handleReset() {
        this.isLoading = true;
        try {
            await refreshApex(this.wiredResult);
            this.runSearch();
        } finally {
            this.isLoading = false;
        }
    }

    extractError(error) {
        if (!error) return 'Unknown error';
        if (typeof error === 'string') return error;
        if (error.body) {
            if (Array.isArray(error.body)) {
                return error.body.map((e) => e.message).join(', ');
            }
            if (typeof error.body.message === 'string') {
                return error.body.message;
            }
        }
        return error.message || 'Unknown error';
    }
}
