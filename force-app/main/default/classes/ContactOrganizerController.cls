public with sharing class ContactOrganizerController {

    private static final Set<String> VALID_ROLES = new Set<String>{
        'C-Suite/Executive',
        'Technology/Ops',
        'Senior User',
        'Junior User'
    };

    public class OrganizerData {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public List<ContactWrapper> contacts;
        @AuraEnabled public List<ExistingAssignment> existingAssignments;
    }

    public class ContactWrapper {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String email;

        public ContactWrapper(Contact c) {
            this.id = c.Id;
            this.name = c.Name;
            this.title = c.Title;
            this.email = c.Email;
        }
    }

    public class ExistingAssignment {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String role;
    }

    public class RelationshipMapInput {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String role;
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
        data.contacts = new List<ContactWrapper>();
        data.existingAssignments = new List<ExistingAssignment>();

        if (opp.AccountId == null) {
            return data;
        }

        for (Contact c : [
            SELECT Id, Name, Title, Email
            FROM Contact
            WHERE AccountId = :opp.AccountId
            ORDER BY Name ASC
        ]) {
            data.contacts.add(new ContactWrapper(c));
        }

        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Role__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opportunityId
        ]) {
            ExistingAssignment ea = new ExistingAssignment();
            ea.contactId = rm.Contact__c;
            ea.role = rm.Role__c;
            data.existingAssignments.add(ea);
        }

        return data;
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

        Map<Id, String> desired = new Map<Id, String>();
        for (RelationshipMapInput input : assignments) {
            if (input.contactId == null || String.isBlank(input.role)) {
                continue;
            }
            if (!VALID_ROLES.contains(input.role)) {
                throw new AuraHandledException('Invalid role: ' + input.role);
            }
            desired.put(input.contactId, input.role);
        }

        Map<Id, Relationship_Map__c> existingByContact = new Map<Id, Relationship_Map__c>();
        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Role__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opportunityId
        ]) {
            existingByContact.put(rm.Contact__c, rm);
        }

        List<Relationship_Map__c> toInsert = new List<Relationship_Map__c>();
        List<Relationship_Map__c> toUpdate = new List<Relationship_Map__c>();
        List<Relationship_Map__c> toDelete = new List<Relationship_Map__c>();

        for (Id contactId : desired.keySet()) {
            String role = desired.get(contactId);
            Relationship_Map__c existing = existingByContact.get(contactId);
            if (existing == null) {
                toInsert.add(new Relationship_Map__c(
                    Contact__c = contactId,
                    Account__c = accountId,
                    Opportunity__c = opportunityId,
                    Role__c = role
                ));
            } else if (existing.Role__c != role) {
                existing.Role__c = role;
                toUpdate.add(existing);
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
