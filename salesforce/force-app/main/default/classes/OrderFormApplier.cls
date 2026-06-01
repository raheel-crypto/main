public with sharing class OrderFormApplier {

    public class Request {
        @InvocableVariable(required=true label='Order Form Extraction Id')
        public Id extractionId;
    }

    public class Result {
        @InvocableVariable(label='Applied') public Boolean applied;
        @InvocableVariable(label='Status') public String status;
        @InvocableVariable(label='Apply Notes') public String notes;
        @InvocableVariable(label='Opportunity Id') public Id opportunityId;
    }

    @InvocableMethod(
        label='Apply Order Form Extraction to Opportunity'
        description='Copies fields from an Order_Form_Extraction__c row onto its parent Opportunity (fill-blanks-only).'
        category='Sales'
    )
    public static List<Result> apply(List<Request> requests) {
        Set<Id> extractionIds = new Set<Id>();
        for (Request r : requests) if (r != null && r.extractionId != null) extractionIds.add(r.extractionId);

        Map<Id, Order_Form_Extraction__c> rowsById = new Map<Id, Order_Form_Extraction__c>([
            SELECT Id, Opportunity__c, Extraction_Status__c, Applied_To_Opportunity__c, Is_Amendment__c,
                   Type__c, Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Months__c,
                   Seat_Licenses__c, License_Fees__c, Platform_Connection_Fee__c, Professional_Service_Fees__c,
                   Total_Contract_Value__c, Annual_Recurring_Revenue__c,
                   Renewal_Terms__c, Subscription_Schedule__c, Payment_Terms__c, Credit_Terms__c,
                   Billing_Contact_Email__c, ELA__c, Paid_Trial__c, Trial_Price__c, Pilot_Success_Criteria__c,
                   Credits_Purchased__c, Credits_Period__c, Special_Terms__c
            FROM Order_Form_Extraction__c
            WHERE Id IN :extractionIds
        ]);

        Set<Id> oppIds = new Set<Id>();
        for (Order_Form_Extraction__c r : rowsById.values()) if (r.Opportunity__c != null) oppIds.add(r.Opportunity__c);

        Map<Id, Opportunity> oppsById = new Map<Id, Opportunity>([
            SELECT Id, Type,
                   Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Mos__c,
                   Seat_Licenses__c, Num_Users__c,
                   License_Fees__c, Platform_Connection_Fee__c, Professional_Service_Fees__c,
                   Total_Contract_Value__c, Amount, Annual_Recurring_Revenue__c,
                   Renewal_Terms__c, Subscription_Schedule__c, Payment_Terms__c, Credit_Terms__c,
                   Billing_Contact__c, ELA__c,
                   Trial_Start_Date__c, Trial_End_Date__c, Trial_Length_Days__c,
                   Trial_Users__c, Trial_Price__c, Paid_Trial__c, Pilot_Success_Criteria__c,
                   Notes__c
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        List<Opportunity> oppsToUpdate = new List<Opportunity>();
        List<Order_Form_Extraction__c> rowsToUpdate = new List<Order_Form_Extraction__c>();
        List<Result> results = new List<Result>();
        Id runningUser = UserInfo.getUserId();
        Datetime now = System.now();

        for (Request req : requests) {
            Result res = new Result();
            res.applied = false;
            results.add(res);

            if (req == null || req.extractionId == null) {
                res.status = 'MissingId';
                res.notes = 'No extractionId supplied.';
                continue;
            }
            Order_Form_Extraction__c row = rowsById.get(req.extractionId);
            if (row == null) {
                res.status = 'NotFound';
                res.notes = 'Extraction ' + req.extractionId + ' not found.';
                continue;
            }
            res.opportunityId = row.Opportunity__c;

            if (row.Extraction_Status__c != 'Success') {
                res.status = 'NotSuccess';
                res.notes = 'Extraction status is "' + row.Extraction_Status__c + '"; skipping apply.';
                continue;
            }
            if (row.Applied_To_Opportunity__c == true) {
                res.status = 'AlreadyApplied';
                res.notes = 'Extraction already applied to Opportunity.';
                continue;
            }
            Opportunity opp = oppsById.get(row.Opportunity__c);
            if (opp == null) {
                res.status = 'OpportunityMissing';
                res.notes = 'Parent Opportunity not accessible.';
                continue;
            }

            List<String> log = new List<String>();
            Opportunity changes = buildFillBlanksUpdate(opp, row, log);
            if (changes != null) oppsToUpdate.add(changes);

            row.Applied_To_Opportunity__c = true;
            row.Applied_At__c = now;
            row.Applied_By__c = runningUser;
            row.Apply_Notes__c = truncate(String.join(log, '\n'), 32768);
            rowsToUpdate.add(row);

            res.applied = true;
            res.status = 'Applied';
            res.notes = row.Apply_Notes__c;
        }

        if (!oppsToUpdate.isEmpty()) update oppsToUpdate;
        if (!rowsToUpdate.isEmpty()) update rowsToUpdate;
        return results;
    }

    private static Opportunity buildFillBlanksUpdate(Opportunity opp, Order_Form_Extraction__c row, List<String> log) {
        Opportunity changes = new Opportunity(Id = opp.Id);
        Boolean anyChange = false;
        Boolean isPilot = 'Pilot'.equals(row.Type__c) || 'Pilot'.equals(opp.Type);

        if (isPilot) {
            anyChange = trySetDate('Trial_Start_Date__c', opp.Trial_Start_Date__c, row.Contract_Start_Date__c, changes, log) || anyChange;
            anyChange = trySetDate('Trial_End_Date__c',   opp.Trial_End_Date__c,   row.Contract_End_Date__c,   changes, log) || anyChange;
            if (opp.Trial_Users__c == null && row.Seat_Licenses__c != null) {
                changes.Trial_Users__c = row.Seat_Licenses__c;
                log.add('Wrote Trial_Users__c=' + row.Seat_Licenses__c);
                anyChange = true;
            } else if (opp.Trial_Users__c != null && row.Seat_Licenses__c != null && opp.Trial_Users__c != row.Seat_Licenses__c) {
                log.add('Skipped Trial_Users__c (existing=' + opp.Trial_Users__c + ', extracted=' + row.Seat_Licenses__c + ')');
            }
            Decimal trialPrice = row.Trial_Price__c != null ? row.Trial_Price__c : row.License_Fees__c;
            if (opp.Trial_Price__c == null && trialPrice != null) {
                changes.Trial_Price__c = trialPrice;
                log.add('Wrote Trial_Price__c=' + trialPrice);
                anyChange = true;
            }
            if (opp.Paid_Trial__c == false && row.Paid_Trial__c == true) {
                changes.Paid_Trial__c = true;
                log.add('Wrote Paid_Trial__c=true');
                anyChange = true;
            }
            if (String.isBlank(opp.Pilot_Success_Criteria__c) && String.isNotBlank(row.Pilot_Success_Criteria__c)) {
                changes.Pilot_Success_Criteria__c = row.Pilot_Success_Criteria__c;
                log.add('Wrote Pilot_Success_Criteria__c');
                anyChange = true;
            }
        } else {
            anyChange = trySetDate('Contract_Start_Date__c', opp.Contract_Start_Date__c, row.Contract_Start_Date__c, changes, log) || anyChange;
            anyChange = trySetDate('Contract_End_Date__c',   opp.Contract_End_Date__c,   row.Contract_End_Date__c,   changes, log) || anyChange;
            if (opp.Contract_Length_Mos__c == null && row.Contract_Length_Months__c != null) {
                changes.Contract_Length_Mos__c = row.Contract_Length_Months__c;
                log.add('Wrote Contract_Length_Mos__c=' + row.Contract_Length_Months__c);
                anyChange = true;
            }
            if (opp.Seat_Licenses__c == null && row.Seat_Licenses__c != null) {
                changes.Seat_Licenses__c = row.Seat_Licenses__c;
                log.add('Wrote Seat_Licenses__c=' + row.Seat_Licenses__c);
                anyChange = true;
            } else if (opp.Seat_Licenses__c != null && row.Seat_Licenses__c != null && opp.Seat_Licenses__c != row.Seat_Licenses__c) {
                log.add('Skipped Seat_Licenses__c (existing=' + opp.Seat_Licenses__c + ', extracted=' + row.Seat_Licenses__c + ')');
            }
            if (opp.Num_Users__c == null && row.Seat_Licenses__c != null) {
                changes.Num_Users__c = row.Seat_Licenses__c;
                log.add('Wrote Num_Users__c=' + row.Seat_Licenses__c);
                anyChange = true;
            }
            if (opp.License_Fees__c == null && row.License_Fees__c != null) {
                changes.License_Fees__c = row.License_Fees__c;
                log.add('Wrote License_Fees__c=' + row.License_Fees__c);
                anyChange = true;
            } else if (opp.License_Fees__c != null && row.License_Fees__c != null && opp.License_Fees__c != row.License_Fees__c) {
                log.add('Skipped License_Fees__c (existing=' + opp.License_Fees__c + ', extracted=' + row.License_Fees__c + ')');
            }
        }

        anyChange = trySetDecimal('Platform_Connection_Fee__c', opp.Platform_Connection_Fee__c, row.Platform_Connection_Fee__c, changes, log) || anyChange;
        anyChange = trySetDecimal('Professional_Service_Fees__c', opp.Professional_Service_Fees__c, row.Professional_Service_Fees__c, changes, log) || anyChange;
        anyChange = trySetDecimal('Total_Contract_Value__c', opp.Total_Contract_Value__c, row.Total_Contract_Value__c, changes, log) || anyChange;
        if (opp.Amount == null && row.Total_Contract_Value__c != null) {
            changes.Amount = row.Total_Contract_Value__c;
            log.add('Wrote Amount=' + row.Total_Contract_Value__c);
            anyChange = true;
        }
        anyChange = trySetDecimal('Annual_Recurring_Revenue__c', opp.Annual_Recurring_Revenue__c, row.Annual_Recurring_Revenue__c, changes, log) || anyChange;
        anyChange = trySetPicklist('Renewal_Terms__c', opp.Renewal_Terms__c, row.Renewal_Terms__c, changes, log) || anyChange;
        anyChange = trySetPicklist('Subscription_Schedule__c', opp.Subscription_Schedule__c, row.Subscription_Schedule__c, changes, log) || anyChange;
        anyChange = trySetPicklist('Payment_Terms__c', opp.Payment_Terms__c, row.Payment_Terms__c, changes, log) || anyChange;
        anyChange = trySetPicklist('Credit_Terms__c', opp.Credit_Terms__c, row.Credit_Terms__c, changes, log) || anyChange;

        if (String.isBlank(opp.Billing_Contact__c) && String.isNotBlank(row.Billing_Contact_Email__c)) {
            changes.Billing_Contact__c = row.Billing_Contact_Email__c;
            log.add('Wrote Billing_Contact__c=' + row.Billing_Contact_Email__c);
            anyChange = true;
        }
        if (opp.ELA__c == false && row.ELA__c == true) {
            changes.ELA__c = true;
            log.add('Wrote ELA__c=true');
            anyChange = true;
        }

        String notesAppendix = composeNotesAppendix(row);
        if (String.isNotBlank(notesAppendix) && String.isBlank(opp.Notes__c)) {
            changes.Notes__c = notesAppendix;
            log.add('Wrote Notes__c (special terms / credits appendix)');
            anyChange = true;
        }

        if (!anyChange) log.add('No fields written; Opportunity already had values for everything extracted.');
        return anyChange ? changes : null;
    }

    private static Boolean trySetDate(String fieldName, Date current, Date extracted, Opportunity changes, List<String> log) {
        if (current == null && extracted != null) {
            changes.put(fieldName, extracted);
            log.add('Wrote ' + fieldName + '=' + extracted);
            return true;
        }
        if (current != null && extracted != null && current != extracted) {
            log.add('Skipped ' + fieldName + ' (existing=' + current + ', extracted=' + extracted + ')');
        }
        return false;
    }

    private static Boolean trySetDecimal(String fieldName, Decimal current, Decimal extracted, Opportunity changes, List<String> log) {
        if (current == null && extracted != null) {
            changes.put(fieldName, extracted);
            log.add('Wrote ' + fieldName + '=' + extracted);
            return true;
        }
        if (current != null && extracted != null && current != extracted) {
            log.add('Skipped ' + fieldName + ' (existing=' + current + ', extracted=' + extracted + ')');
        }
        return false;
    }

    private static Boolean trySetPicklist(String fieldName, String current, String extracted, Opportunity changes, List<String> log) {
        if (String.isBlank(current) && String.isNotBlank(extracted)) {
            changes.put(fieldName, extracted);
            log.add('Wrote ' + fieldName + '=' + extracted);
            return true;
        }
        if (String.isNotBlank(current) && String.isNotBlank(extracted) && !current.equals(extracted)) {
            log.add('Skipped ' + fieldName + ' (existing=' + current + ', extracted=' + extracted + ')');
        }
        return false;
    }

    private static String composeNotesAppendix(Order_Form_Extraction__c row) {
        List<String> parts = new List<String>();
        if (row.Credits_Purchased__c != null) {
            String periodStr = String.isNotBlank(row.Credits_Period__c) ? ' per ' + row.Credits_Period__c : '';
            parts.add('Credits: ' + row.Credits_Purchased__c.toPlainString() + periodStr);
        }
        if (String.isNotBlank(row.Special_Terms__c)) parts.add('Special terms: ' + row.Special_Terms__c);
        if (row.Is_Amendment__c == true) parts.add('[Source: amendment / rider]');
        return parts.isEmpty() ? null : String.join(parts, '\n');
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return null;
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }
}
