export type OpportunityType =
  | "New Business"
  | "Renewal"
  | "Upsell"
  | "Downsell"
  | "Pilot"
  | "Contract Restructure"
  | "Debooking";

export type AccountStatus = "Prospect" | "Customer" | "Former Customer";

export interface OpportunityRecord {
  Id: string;
  AccountId: string;
  Annual_Recurring_Revenue__c: number | null;
  Type: OpportunityType;
  CloseDate: string;
  IsWon: boolean;
  Name?: string;
  ARR_Locked__c?: boolean;
}

export interface AccountRecord {
  Id: string;
  Name: string;
  ARR__c: number | null;
  Account_Status__c: AccountStatus;
  Churn_Date__c: string | null;
}

// Note: "Restructure (delta/absorbed)" is one combined picklist value in
// Salesforce; the delta vs absorbed distinction is preserved in the event note.
export type EventType =
  | "New Business"
  | "Upsell"
  | "Pilot"
  | "Downsell"
  | "Debooking"
  | "Renewal (rebase)"
  | "Restructure (delta/absorbed)"
  | "Churn";

export interface ArrEvent {
  opportunityId: string | null;
  eventDate: string;
  eventType: EventType;
  delta: number;
  running: number;
  sequence: number;
  note: string;
  isSynthetic: boolean;
}

export interface RecomputeResult {
  accountId: string;
  expectedArr: number;
  events: ArrEvent[];
  status: AccountStatus;
}
