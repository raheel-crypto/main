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
}
