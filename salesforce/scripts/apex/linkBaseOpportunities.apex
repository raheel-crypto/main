// =============================================================================
// Link unlinked Closed Won amendments to their base deal (Base_Opportunity__c)
// =============================================================================
// Pairs come from the reviewed report base_opportunity_suggestions.csv
// (2026-10-08): 101 High, 8 Medium, 1 Low confidence. Rule: the account's latest
// Closed Won New Business / Renewal on or before the amendment's close date,
// preferring the base other amendments on the account already use, skipping
// deals typed New Business but named like an upsell, and matching [Arvo] deals
// to [Arvo] deals. The extractor needs the base deal to measure an upsell's
// increment (Incremental ARR / Seats / Credits) against the prior paper.
//
// SAFETY:
//   * DRY_RUN = true (default) prints every link it WOULD make and writes nothing.
//   * Never overwrites a Base_Opportunity__c someone has set since the report.
//   * Saves row by row (allOrNone = false) and prints any row a validation rule
//     or flow rejects. Opportunity flows run on the update as on any edit.
//   * FLAG_RERUN ticks Rerun__c on each linked deal's current extraction, so
//     rerunFlaggedExtractions.apex re-reads them against their base.
//
// Run: sf apex run --target-org rogo --file scripts/apex/linkBaseOpportunities.apex
// =============================================================================

Boolean DRY_RUN = true;                                        // <-- false to write
Set<String> APPLY = new Set<String>{ 'High', 'Medium' };     // add 'Low' to include it
Set<String> SKIP = new Set<String>{};                         // amendment Ids to leave alone
Boolean FLAG_RERUN = true;

Map<String, String> high = new Map<String, String>{
    '006cv00000mRDNJAA4' => '006cv00000KQ2qfAAD',
    '006cv00000piuXOAAY' => '006V400000KkSaTIAV',
    '006cv00000qkmVBAAY' => '006V400000KkSaTIAV',
    '006cv00000rkPbBAAU' => '006cv00000gOtxdAAC',
    '006cv00000ZRrLsAAL' => '006cv00000SdkAwAAJ',
    '006cv00000kcL8zAAE' => '006V400000N4rtKIAR',
    '006cv00000lGWP9AAO' => '006V400000N4rtKIAR',
    '006cv00000nhq8qAAA' => '006cv00000Q5wysAAB',
    '006cv00000hx149AAA' => '006cv00000Q5wysAAB',
    '006cv00000pS2EQAA0' => '006cv00000Q5wysAAB',
    '006cv00000puFOnAAM' => '006cv00000Q5wysAAB',
    '006cv00000qA3UvAAK' => '006cv00000llcV2AAI',
    '006cv00000nzPJpAAM' => '006V400000D4kUbIAJ',
    '006cv00000qAATEAA4' => '006V400000D4kUbIAJ',
    '006cv00000hltwMAAQ' => '006V400000D4kUbIAJ',
    '006cv00000g5esfAAA' => '006cv00000Xlku1AAB',
    '006cv00000dhqZaAAI' => '006V400000GjczBIAR',
    '006cv00000nHIAqAAO' => '006V400000JUV8HIAX',
    '006cv00000cu7H3AAI' => '006cv00000XrbQ1AAJ',
    '006cv00000bp9vBAAQ' => '006V400000NX9vKIAT',
    '006cv00000ma2XXAAY' => '006V400000JiJ5dIAF',
    '006cv00000nx1lSAAQ' => '006V4000007S7QjIAK',
    '006cv00000gnaF3AAI' => '006V4000007S7QjIAK',
    '006cv00000efWeQAAU' => '006cv00000KWsBTAA1',
    '006cv00000gNYP0AAO' => '006cv00000KWsBTAA1',
    '006cv00000k2yf8AAA' => '006cv00000aZEszAAG',
    '006cv00000gvaOLAAY' => '006cv00000a9BsMAAU',
    '006cv00000fbqBKAAY' => '006V400000Jb3dWIAR',
    '006cv00000kQppBAAS' => '006V400000Jb3dWIAR',
    '006cv00000nFDQYAA4' => '006V400000NsEGNIA3',
    '006cv00000qiawJAAQ' => '006cv00000mxr1RAAQ',
    '006cv00000eRlWuAAK' => '006V400000JAv6vIAD',
    '006cv00000fvfjZAAQ' => '006V400000JAv6vIAD',
    '006cv00000QNvhoAAD' => '006cv00000PQcJNAA1',
    '006cv00000jXFhXAAW' => '006cv00000NF4sUAAT',
    '006cv00000nHIAnAAO' => '006cv00000NF4sUAAT',
    '006cv00000c9DplAAE' => '006cv00000Or2QzAAJ',
    '006cv00000rMMzRAAW' => '006cv00000Or2QzAAJ',
    '006cv00000sYdj0AAC' => '006V400000LOUyXIAX',
    '006cv00000nfynDAAQ' => '006cv00000ZeobRAAR',
    '006cv00000cxA8lAAE' => '006V400000LRgOsIAL',
    '006cv00000fB5CrAAK' => '006V400000LRgOsIAL',
    '006cv00000sXKYpAAO' => '006V400000Lp2gPIAR',
    '006cv00000orUZRAA2' => '006V400000JbF0LIAV',
    '006cv00000LsWuuAAF' => '006V4000004xT6xIAE',
    '006cv00000pcXiQAAU' => '006V400000CK5npIAD',
    '006cv00000qQ0ssAAC' => '006V400000CK5npIAD',
    '006cv00000ptLzKAAU' => '006V400000IbDf4IAF',
    '006cv00000moLdVAAU' => '006cv00000ln0bhAAA',
    '006cv00000jFhM8AAK' => '006cv00000gfprCAAQ',
    '006cv00000sdlfuAAA' => '006V400000MAu4HIAT',
    '006cv00000aPlbhAAC' => '006cv00000NUcYtAAL',
    '006cv00000l5dQjAAI' => '006V400000I3jmEIAR',
    '006cv00000ns3BEAAY' => '006cv00000SqnirAAB',
    '006cv00000dAcC6AAK' => '006cv00000Q1dy2AAB',
    '006cv00000h3z9RAAQ' => '006Hr00001OL9tpIAD',
    '006cv00000h3VwAAAU' => '006Hr00001OL9tpIAD',
    '006cv00000jfrzJAAQ' => '006cv00000We5o9AAB',
    '006cv00000rW3KUAA0' => '006cv00000We5o9AAB',
    '006cv00000kZnmZAAS' => '006cv00000V1ywLAAR',
    '006cv00000s2p2bAAA' => '006cv00000d7ysDAAQ',
    '006cv00000cusuHAAQ' => '006V400000C6a3VIAR',
    '006cv00000eQt1qAAC' => '006cv00000QOaUoAAL',
    '006cv00000dAfY9AAK' => '006cv00000Mpx32AAB',
    '006cv00000g5WS7AAM' => '006cv00000bJynzAAC',
    '006cv00000rXH6pAAG' => '006cv00000QOEanAAH',
    '006cv00000c04YnAAI' => '006V400000JY2pFIAT',
    '006cv00000fPwdtAAC' => '006V400000JY2pFIAT',
    '006cv00000XW7wDAAT' => '006V400000DYy5WIAT',
    '006cv00000kXlNRAA0' => '006V400000DYy5WIAT',
    '006cv00000qpyNaAAI' => '006cv00000RLGGjAAP',
    '006cv00000sYJfSAAW' => '006cv00000lmX0IAAU',
    '006cv00000fBBYPAA4' => '006V400000Bi7gzIAB',
    '006cv00000lzuocAAA' => '006V400000Bi7gzIAB',
    '006cv00000p9M2MAAU' => '006V400000Bi7gzIAB',
    '006cv00000ki2mrAAA' => '006cv00000OP6nZAAT',
    '006cv00000UlsOlAAJ' => '006cv00000ZnSiQAAV',
    '006cv00000igrpmAAA' => '006cv00000Z5qUsAAJ',
    '006cv00000cvg33AAA' => '006V400000HjpqzIAB',
    '006cv00000fcf0vAAA' => '006cv00000Qp0K0AAJ',
    '006cv00000qUXdOAAW' => '006cv00000Qp0K0AAJ',
    '006cv00000gFBRBAA4' => '006cv00000Qp0K0AAJ',
    '006cv00000nUVyEAAW' => '006cv00000NTlUXAA1',
    '006cv00000q5kqiAAA' => '006cv00000NTlUXAA1',
    '006cv00000kRinFAAS' => '006V4000007OZgYIAW',
    '006cv00000lvmUhAAI' => '006V4000007OZgYIAW',
    '006cv00000qA2llAAC' => '006cv00000lm3S6AAI',
    '006cv00000eqaTQAAY' => '006cv00000S0jt4AAB',
    '006cv00000rdJM1AAM' => '006V400000JiESYIA3',
    '006cv00000jfpXjAAI' => '006cv00000fBI22AAG',
    '006cv00000rRLBVAA4' => '006V400000JZCBSIA5',
    '006cv00000rU4ajAAC' => '006cv00000jx1asAAA',
    '006cv00000euSllAAE' => '006cv00000ZaagjAAB',
    '006cv00000fRWiZAAW' => '006cv00000ZaagjAAB',
    '006cv00000jddkOAAQ' => '006cv00000ZaagjAAB',
    '006cv00000eXdhuAAC' => '006cv00000ZaagjAAB',
    '006cv00000rY7bfAAC' => '006cv00000W1b7xAAB',
    '006cv00000ruaFJAAY' => '006cv00000UJxG5AAL',
    '006cv00000riCLWAA2' => '006cv00000llZIhAAM',
    '006cv00000rzSnFAAU' => '006cv00000bsdlTAAQ',
    '006cv00000skFeTAAU' => '006cv00000m5kMlAAI'
};

Map<String, String> medium = new Map<String, String>{
    '006cv00000dx2CEAAY' => '006V400000Fpd8LIAR',
    '006cv00000rjucFAAQ' => '006V400000DeSJ6IAN',
    '006cv00000lsMLSAA2' => '006cv00000UPcATAA1',
    '006cv00000racczAAA' => '006V400000GFsrhIAD',
    '006cv00000qGeBdAAK' => '006V400000BDNYMIA5',
    '006cv00000sWoKOAA0' => '006V400000L8g1CIAR',
    '006cv00000gPlQAAA0' => '006cv00000RUSnJAAX',
    '006cv00000hCC36AAG' => '006cv00000RUSnJAAX'
};

Map<String, String> low = new Map<String, String>{
    '006cv00000or5j8AAA' => '006cv00000lmEQcAAM'
};

Map<String, Map<String, String>> byConfidence = new Map<String, Map<String, String>>{
    'High' => high, 'Medium' => medium, 'Low' => low
};
Map<Id, Id> plan = new Map<Id, Id>();
Map<Id, String> confidenceOf = new Map<Id, String>();
for (String conf : byConfidence.keySet()) {
    if (!APPLY.contains(conf)) continue;
    Map<String, String> pairs = byConfidence.get(conf);
    for (String amendId : pairs.keySet()) {
        if (SKIP.contains(amendId)) continue;
        plan.put(Id.valueOf(amendId), Id.valueOf(pairs.get(amendId)));
        confidenceOf.put(Id.valueOf(amendId), conf);
    }
}

Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
    SELECT Id, Name, Base_Opportunity__c FROM Opportunity WHERE Id IN :plan.keySet()
]);
Map<Id, Opportunity> bases = new Map<Id, Opportunity>([
    SELECT Id, Name FROM Opportunity WHERE Id IN :plan.values()
]);
List<Opportunity> updates = new List<Opportunity>();
Integer alreadyLinked = 0;
for (Id oppId : plan.keySet()) {
    Opportunity o = opps.get(oppId);
    Opportunity b = bases.get(plan.get(oppId));
    if (o == null || b == null) continue;
    if (o.Base_Opportunity__c != null) { alreadyLinked++; continue; }
    System.debug(confidenceOf.get(oppId) + ' | ' + o.Name + '  ->  ' + b.Name);
    updates.add(new Opportunity(Id = oppId, Base_Opportunity__c = b.Id));
}
System.debug('--- ' + updates.size() + ' link(s) planned; ' + alreadyLinked + ' already linked since the report (left alone).');
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to apply.');
    return;
}

Set<Id> linked = new Set<Id>();
Integer i = 0;
for (Database.SaveResult sr : Database.update(updates, false)) {
    Opportunity o = updates[i++];
    if (sr.isSuccess()) { linked.add(o.Id); continue; }
    String msg = '';
    for (Database.Error e : sr.getErrors()) msg += e.getMessage() + ' ';
    System.debug('FAILED | ' + opps.get(o.Id).Name + ' | ' + msg);
}
System.debug('--- Linked ' + linked.size() + ' of ' + updates.size() + '.');

if (FLAG_RERUN && !linked.isEmpty()) {
    List<Order_Form_Extraction__c> flags = [
        SELECT Id FROM Order_Form_Extraction__c WHERE Opportunity__c IN :linked AND Is_Current__c = true
    ];
    for (Order_Form_Extraction__c f : flags) f.Rerun__c = true;
    update flags;
    System.debug('--- Flagged ' + flags.size() + ' current extraction(s) for rerun. Next: rerunFlaggedExtractions.apex');
}
