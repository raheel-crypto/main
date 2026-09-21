public with sharing class OrderFormPicklistMapper {

    public static String mapType(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('pilot') || s.contains('trial') || s.contains('proof of concept') || s.contains('poc')) return 'Pilot';
        if (s.contains('renew')) return 'Renewal';
        if (s.contains('upsell') || s.contains('expansion') || s.contains('add-on') || s.contains('addon')) return 'Upsell';
        if (s.contains('downsell') || s.contains('reduction')) return 'Downsell';
        if (s.contains('restructure')) return 'Contract Restructure';
        if (s.contains('debook')) return 'Debooking';
        if (s.contains('new business') || s.contains('new')) return 'New Business';
        return null;
    }

    public static String mapRenewalTerms(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('manual') || s.contains('mutual') || s.contains('no auto') || s.contains('will not auto')) return 'Manual renewal';
        if (s.contains('90')) return 'Auto-renew (90-day)';
        if (s.contains('60')) return 'Auto-renew (60-day)';
        if (s.contains('30')) return 'Auto-renew (30-day)';
        if (s.contains('auto') || s.contains('evergreen')) return 'Auto-renew (30-day)';
        return null;
    }

    public static String mapSubscriptionSchedule(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('bi-annual') || s.contains('semi-annual') || s.contains('biannual') || s.contains('semiannual')) return 'Bi-Annual';
        if (s.contains('quarter')) return 'Quarterly';
        if (s.contains('month')) return 'Monthly';
        if (s.contains('annual') || s.contains('yearly') || s.contains('year')) return 'Annual';
        return null;
    }

    public static String mapPaymentTerms(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('semi-annual') || s.contains('semiannual')) return 'Semi-Annual';
        if (s.contains('quarter')) return 'Quarterly';
        if (s.contains('month')) return 'Monthly';
        if (s.contains('annual') || s.contains('yearly')) return 'Annual';
        return null;
    }

    public static String mapCreditTerms(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase().replaceAll('\\s+', '');
        if (s.contains('net15') || s.contains('net-15')) return 'Net-15';
        if (s.contains('net30') || s.contains('net-30')) return 'Net-30';
        if (s.contains('net45') || s.contains('net-45')) return 'Net-45';
        if (s.contains('net60') || s.contains('net-60')) return 'Net-60';
        return null;
    }

    public static String mapPackageTier(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('enterprise')) return 'Enterprise';
        if (s.contains('team')) return 'Team';
        if (s.contains('basic')) return 'Basic';
        if (s.contains('custom') || s.contains('bespoke')) return 'Custom';
        return null;
    }

    public static String mapPricingStructure(String raw) {
        if (String.isBlank(raw)) return null;
        Set<String> allowed = new Set<String>{
            'Seats: Unlimited Usage, No Throttling',
            'Seats: Unlimited Usage, with Throttling',
            'Seats: Credit-Based Usage',
            'ELA: Unlimited Usage, No Throttling',
            'ELA: Unlimited Usage, with Throttling',
            'ELA: Credit-Based Usage',
            'Custom'
        };
        if (allowed.contains(raw)) return raw;
        String s = raw.toLowerCase();
        Boolean isEla = s.contains('ela') || s.contains('enterprise license');
        Boolean isCredit = s.contains('credit');
        Boolean isThrottled = s.contains('throttl') || s.contains('fair use') || s.contains('rate limit');
        Boolean isUnlimited = s.contains('unlimited');
        String prefix = isEla ? 'ELA' : 'Seats';
        if (isCredit) return prefix + ': Credit-Based Usage';
        if (isUnlimited && isThrottled) return prefix + ': Unlimited Usage, with Throttling';
        if (isUnlimited) return prefix + ': Unlimited Usage, No Throttling';
        if (s.contains('custom')) return 'Custom';
        return null;
    }

    // Rogo's right to use the customer's name/logo/marks for publicity.
    // Defaults to 'Not Mentioned' (never null) - the field should always carry a
    // value. Order matters: none -> conditions -> no -> yes.
    public static String mapPublicityRights(String raw) {
        if (String.isBlank(raw)) return 'Not Mentioned';
        String s = raw.toLowerCase();
        if (s.contains('not mentioned') || s.contains('not specified')
            || s.contains('none') || s.contains('n/a') || s.contains('silent')) return 'Not Mentioned';
        if (s.contains('condition') || s.contains('consent') || s.contains('approv')
            || s.contains('restrict') || s.contains('opt out') || s.contains('opt-out')) return 'With Conditions';
        if (s.startsWith('no') || s.contains('prohibit') || s.contains('not permit')
            || s.contains('shall not') || s.contains('may not')) return 'No';
        if (s.contains('yes') || s.contains('permit') || s.contains('grant') || s.contains('allow')) return 'Yes';
        return 'Not Mentioned';
    }

    // ===== LLM enablement gate mappers (all default to a safe "silence" value) =====

    // Yes / No / Not specified. Check "not specified" first ("not" contains "no").
    public static String mapYesNoNotSpecified(String raw) {
        if (String.isBlank(raw)) return 'Not specified';
        String s = raw.toLowerCase();
        if (s.contains('not specified') || s.contains('n/a') || s.contains('silent') || s.contains('unknown')) return 'Not specified';
        if (s.startsWith('yes') || s == 'true') return 'Yes';
        if (s.startsWith('no') || s == 'false') return 'No';
        return 'Not specified';
    }

    // Subprocessor_Gate_Type: strictest wins on ambiguity. consent > objection > notify > none.
    public static String mapGateType(String raw) {
        if (String.isBlank(raw)) return 'Not specified';
        String s = raw.toLowerCase();
        if (s.contains('consent') || s.contains('approval') || s.contains('approve')) return 'Consent required';
        if (s.contains('objection') || s.contains('object')) return 'Notify with objection';
        if (s.contains('notify') || s.contains('notice')) return 'Notify';
        if (s == 'none' || s.contains('no gate') || s.contains('no restriction') || s.contains('freely')) return 'None';
        return 'Not specified';
    }

    // Processing_Location_Gate: None / Notice / Consent / Not specified.
    public static String mapLocationGate(String raw) {
        if (String.isBlank(raw)) return 'Not specified';
        String s = raw.toLowerCase();
        if (s.contains('consent') || s.contains('approval') || s.contains('approve')) return 'Consent';
        if (s.contains('notice') || s.contains('notify')) return 'Notice';
        if (s == 'none' || s.contains('no gate') || s.contains('not fixed') || s.contains('anywhere')) return 'None';
        return 'Not specified';
    }

    // Personal_Data_Disclosure_Gate: None / Notify / Consent / Not specified.
    public static String mapDisclosureGate(String raw) {
        if (String.isBlank(raw)) return 'Not specified';
        String s = raw.toLowerCase();
        if (s.contains('consent') || s.contains('approval') || s.contains('approve')) return 'Consent';
        if (s.contains('notify') || s.contains('notice')) return 'Notify';
        if (s == 'none' || s.contains('no gate')) return 'None';
        return 'Not specified';
    }

    // Subprocessor_List_Location: default "Not listed".
    public static String mapListLocation(String raw) {
        if (String.isBlank(raw)) return 'Not listed';
        String s = raw.toLowerCase();
        if (s.contains('transaction')) return 'Transaction document';
        if (s.contains('trust')) return 'Trust page';
        if (s.contains('dpa') || s.contains('data processing') || s.contains('appendix') || s.contains('annex')) return 'DPA appendix';
        if (s.contains('order form') || s.contains('order-form')) return 'Order form';
        if (s.contains('schedule')) return 'Schedule';
        if (s.contains('not listed') || s.contains('none') || s.contains('not found')) return 'Not listed';
        return 'Not listed';
    }

    // Subprocessor_List_Granularity: Provider / Model / Service scoped / Not specified.
    public static String mapListGranularity(String raw) {
        if (String.isBlank(raw)) return 'Not specified';
        String s = raw.toLowerCase();
        if (s.contains('service scoped') || s.contains('service-scoped') || s.contains('scoped') || s.contains('function')) return 'Service scoped';
        if (s.contains('model')) return 'Model';
        if (s.contains('provider') || s.contains('vendor')) return 'Provider';
        return 'Not specified';
    }

    // LLM_Gate_Confidence: default Low (route to review when unknown).
    public static String mapConfidence(String raw) {
        if (String.isBlank(raw)) return 'Low';
        String s = raw.toLowerCase();
        if (s.contains('high')) return 'High';
        if (s.contains('medium') || s.contains('med')) return 'Medium';
        if (s.contains('low')) return 'Low';
        return 'Low';
    }
}
