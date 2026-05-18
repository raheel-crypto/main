public with sharing class ContactOrganizerController {

    private static final Set<String> VALID_ROLES = new Set<String>{
        'C-Suite/Executive',
        'Technology/Ops',
        'Senior User',
        'Junior User'
    };

    private static final Integer SEARCH_LIMIT = 50;

    public class OrganizerData {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Integer totalContacts;
        @AuraEnabled public List<AssignmentWrapper> assignments;
    }

    public class AssignmentWrapper {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String email;
        @AuraEnabled public String role;
        @AuraEnabled public Boolean isChampion;
    }

    public class ContactWrapper {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String email;
    }

    public class RelationshipMapInput {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String role;
        @AuraEnabled public Boolean isChampion;
    }

    @AuraEnabled(cacheable=true)
    public static OrganizerData loadOrganizer(Id opportunityId) {
        if (opportunityId == null) {
            throw new AuraHandledException('Opportunity Id is required.');
        }

        List<Opportunity> opps = [
            SELECT Id, AccountId, Account.Name
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity not found.');
        }
        Opportunity opp = opps[0];

        OrganizerData data = new OrganizerData();
        data.opportunityId = opp.Id;
        data.accountId = opp.AccountId;
        data.accountName = opp.Account != null ? opp.Account.Name : null;
        data.assignments = new List<AssignmentWrapper>();
        data.totalContacts = 0;

        if (opp.AccountId == null) {
            return data;
        }

        data.totalContacts = [SELECT COUNT() FROM Contact WHERE AccountId = :opp.AccountId];

        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Contact__r.Name, Contact__r.Title, Contact__r.Email,
                   Role__c, Champion__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opportunityId
        ]) {
            AssignmentWrapper a = new AssignmentWrapper();
            a.contactId = rm.Contact__c;
            a.name = rm.Contact__r != null ? rm.Contact__r.Name : null;
            a.title = rm.Contact__r != null ? rm.Contact__r.Title : null;
            a.email = rm.Contact__r != null ? rm.Contact__r.Email : null;
            a.role = rm.Role__c;
            a.isChampion = rm.Champion__c;
            data.assignments.add(a);
        }
        return data;
    }

    @AuraEnabled(cacheable=true)
    public static List<ContactWrapper> searchAccountContacts(Id accountId, String searchTerm, List<Id> excludeIds) {
        List<ContactWrapper> results = new List<ContactWrapper>();
        if (accountId == null) {
            return results;
        }
        Set<Id> excludeSet = new Set<Id>();
        if (excludeIds != null) {
            excludeSet.addAll(excludeIds);
        }

        List<Contact> rows;
        if (String.isBlank(searchTerm)) {
            rows = [
                SELECT Id, Name, Title, Email
                FROM Contact
                WHERE AccountId = :accountId
                  AND Id NOT IN :excludeSet
                ORDER BY Name ASC
                LIMIT :SEARCH_LIMIT
            ];
        } else {
            String term = '%' + searchTerm.trim() + '%';
            rows = [
                SELECT Id, Name, Title, Email
                FROM Contact
                WHERE AccountId = :accountId
                  AND Id NOT IN :excludeSet
                  AND (Name LIKE :term OR Title LIKE :term OR Email LIKE :term)
                ORDER BY Name ASC
                LIMIT :SEARCH_LIMIT
            ];
        }

        for (Contact c : rows) {
            ContactWrapper w = new ContactWrapper();
            w.id = c.Id;
            w.name = c.Name;
            w.title = c.Title;
            w.email = c.Email;
            results.add(w);
        }
        return results;
    }

    @AuraEnabled
    public static void saveAssignments(Id opportunityId, List<RelationshipMapInput> assignments) {
        if (opportunityId == null) {
            throw new AuraHandledException('Opportunity Id is required.');
        }
        if (assignments == null) {
            assignments = new List<RelationshipMapInput>();
        }

        List<Opportunity> opps = [
            SELECT Id, AccountId
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity not found.');
        }
        Id accountId = opps[0].AccountId;
        if (accountId == null) {
            throw new AuraHandledException('Opportunity has no Account.');
        }

        Map<Id, RelationshipMapInput> desired = new Map<Id, RelationshipMapInput>();
        for (RelationshipMapInput input : assignments) {
            if (input.contactId == null || String.isBlank(input.role)) {
                continue;
            }
            if (!VALID_ROLES.contains(input.role)) {
                throw new AuraHandledException('Invalid role: ' + input.role);
            }
            if (input.isChampion == null) {
                input.isChampion = false;
            }
            desired.put(input.contactId, input);
        }

        Map<Id, Relationship_Map__c> existingByContact = new Map<Id, Relationship_Map__c>();
        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Role__c, Champion__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opportunityId
        ]) {
            existingByContact.put(rm.Contact__c, rm);
        }

        List<Relationship_Map__c> toInsert = new List<Relationship_Map__c>();
        List<Relationship_Map__c> toUpdate = new List<Relationship_Map__c>();
        List<Relationship_Map__c> toDelete = new List<Relationship_Map__c>();

        for (Id contactId : desired.keySet()) {
            RelationshipMapInput input = desired.get(contactId);
            Relationship_Map__c existing = existingByContact.get(contactId);
            if (existing == null) {
                toInsert.add(new Relationship_Map__c(
                    Contact__c = contactId,
                    Account__c = accountId,
                    Opportunity__c = opportunityId,
                    Role__c = input.role,
                    Champion__c = input.isChampion
                ));
            } else {
                Boolean changed = false;
                if (existing.Role__c != input.role) {
                    existing.Role__c = input.role;
                    changed = true;
                }
                if (existing.Champion__c != input.isChampion) {
                    existing.Champion__c = input.isChampion;
                    changed = true;
                }
                if (changed) {
                    toUpdate.add(existing);
                }
            }
        }

        for (Id contactId : existingByContact.keySet()) {
            if (!desired.containsKey(contactId)) {
                toDelete.add(existingByContact.get(contactId));
            }
        }

        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate;
        if (!toDelete.isEmpty()) delete toDelete;
    }
}
