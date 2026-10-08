// =============================================================================
// One-off: fill the Contract usage + product fields from applied extractions
// =============================================================================
// Package Tier, Unlimited Lite, Free Max/Mid, Free Tier Retained, Overage Rate,
// Credits Per Year, Credit Rate (blended) and Pricing Structure, recomputed on
// every Contract that already has applied extractions (ContractUsageRollup).
// Touches ONLY those fields - no legal terms, no review flags, no ARR / seats /
// fees (the Opportunity flows own those). Safe to re-run; it only writes what
// changed and logs it in Reconciliation Notes.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillContractUsage.apex
// Then watch Setup -> Apex Jobs (ContractUsageRollup), 50 contracts per chunk.
// =============================================================================

Id jobId = ContractUsageRollup.runBackfill();
System.debug('--- Started ContractUsageRollup ' + jobId + '. Monitor in Setup -> Apex Jobs.');
