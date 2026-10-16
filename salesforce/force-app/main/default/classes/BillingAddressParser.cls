/**
 * Splits a one-line billing address (as the order form extraction stores it)
 * into street / city / state / postal code / country for the standard
 * Contract billing address. Deliberately conservative: it recognises the
 * shapes that cover most of the book (US "City, ST 12345", UK postcodes,
 * Canadian / Australian "City PR code", European "12345 City", "City 12345",
 * trailing country names) and returns null when it cannot tell the city from
 * the street - the full line is kept in its own field either way.
 */
public with sharing class BillingAddressParser {

    public class Parts {
        public String street;
        public String city;
        public String state;
        public String postalCode;
        public String country;
    }

    private static final Set<String> US_STATES = new Set<String>{
        'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD',
        'MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC',
        'SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC','PR'
    };
    private static final Set<String> CA_PROVINCES = new Set<String>{
        'AB','BC','MB','NB','NL','NS','NT','NU','ON','PE','QC','SK','YT'
    };
    private static final Set<String> AU_STATES = new Set<String>{ 'NSW','VIC','QLD','WA','SA','TAS','ACT','NT' };
    private static final Set<String> CITY_STATES = new Set<String>{ 'Hong Kong', 'Singapore', 'Luxembourg', 'Monaco' };

    private static final Map<String, String> STATE_NAMES = new Map<String, String>{
        'alabama' => 'AL', 'alaska' => 'AK', 'arizona' => 'AZ', 'arkansas' => 'AR', 'california' => 'CA',
        'colorado' => 'CO', 'connecticut' => 'CT', 'delaware' => 'DE', 'florida' => 'FL', 'georgia' => 'GA',
        'hawaii' => 'HI', 'idaho' => 'ID', 'illinois' => 'IL', 'indiana' => 'IN', 'iowa' => 'IA',
        'kansas' => 'KS', 'kentucky' => 'KY', 'louisiana' => 'LA', 'maine' => 'ME', 'maryland' => 'MD',
        'massachusetts' => 'MA', 'michigan' => 'MI', 'minnesota' => 'MN', 'mississippi' => 'MS',
        'missouri' => 'MO', 'montana' => 'MT', 'nebraska' => 'NE', 'nevada' => 'NV', 'new hampshire' => 'NH',
        'new jersey' => 'NJ', 'new mexico' => 'NM', 'new york' => 'NY', 'north carolina' => 'NC',
        'north dakota' => 'ND', 'ohio' => 'OH', 'oklahoma' => 'OK', 'oregon' => 'OR', 'pennsylvania' => 'PA',
        'rhode island' => 'RI', 'south carolina' => 'SC', 'south dakota' => 'SD', 'tennessee' => 'TN',
        'texas' => 'TX', 'utah' => 'UT', 'vermont' => 'VT', 'virginia' => 'VA', 'washington' => 'WA',
        'west virginia' => 'WV', 'wisconsin' => 'WI', 'wyoming' => 'WY', 'district of columbia' => 'DC'
    };

    // Lower-case name or alias (dots removed) -> country name.
    private static final Map<String, String> COUNTRIES = buildCountries();

    private static Map<String, String> buildCountries() {
        Map<String, String> m = new Map<String, String>();
        for (String k : new List<String>{ 'usa', 'us', 'united states', 'united states of america' }) m.put(k, 'United States');
        for (String k : new List<String>{ 'uk', 'united kingdom', 'england', 'great britain', 'scotland', 'wales',
                'northern ireland' }) m.put(k, 'United Kingdom');
        for (String n : new List<String>{ 'Germany', 'France', 'Spain', 'Italy', 'Switzerland', 'Austria',
                'Netherlands', 'Belgium', 'Luxembourg', 'Ireland', 'Sweden', 'Norway', 'Denmark', 'Finland',
                'Japan', 'China', 'Hong Kong', 'Singapore', 'Australia', 'Canada', 'South Africa', 'India',
                'Israel', 'United Arab Emirates', 'Brazil', 'Mexico', 'Poland', 'Portugal', 'Czech Republic',
                'South Korea', 'Taiwan', 'New Zealand', 'Saudi Arabia', 'Qatar', 'Monaco', 'Liechtenstein',
                'Cayman Islands', 'Bermuda', 'Jersey', 'Guernsey', 'Greece', 'Turkey', 'Hungary', 'Romania',
                'Iceland', 'Malta', 'Cyprus', 'Chile', 'Argentina', 'Colombia', 'Peru', 'Indonesia', 'Malaysia',
                'Philippines', 'Thailand', 'Vietnam', 'Kuwait', 'Bahrain', 'Egypt', 'Nigeria', 'Kenya' }) {
            m.put(n.toLowerCase(), n);
        }
        m.put('the netherlands', 'Netherlands');
        m.put('swiss', 'Switzerland');
        m.put('uae', 'United Arab Emirates');
        m.put('korea', 'South Korea');
        return m;
    }

    private static final String STATE_NAME_ALT = buildStateNameAlternation();

    private static String buildStateNameAlternation() {
        // Longest first so "west virginia" wins over "virginia".
        List<String> names = new List<String>(STATE_NAMES.keySet());
        List<String> ordered = new List<String>();
        for (Integer len = 30; len > 0; len--) {
            for (String n : names) if (n.length() == len) ordered.add(n);
        }
        return String.join(ordered, '|');
    }

    private static final String EN_DASH = String.fromCharArray(new List<Integer>{ 8211 });
    private static final String EM_DASH = String.fromCharArray(new List<Integer>{ 8212 });
    private static final Pattern TRAILING_NOTE = Pattern.compile('\\s*\\([^)]*\\)\\s*$');
    private static final Pattern TRAILING_COUNTRY = Pattern.compile(
        '(?i)^(.*\\S)\\s+(USA|U\\.S\\.A\\.|United States|UK|United Kingdom)$');
    private static final Pattern US_TAIL = Pattern.compile('^(?:(.+?)\\s+)?([A-Za-z]{2})\\.?\\s+(\\d{5}(?:-\\d{4})?)$');
    private static final Pattern US_NAME_TAIL = Pattern.compile(
        '(?i)^(?:(.+?)\\s+)?(' + STATE_NAME_ALT + ')\\s+(\\d{5}(?:-\\d{4})?)$');
    private static final Pattern STATE_ONLY = Pattern.compile('^(?:(.+?)\\s+)?([A-Za-z]{2})$');
    private static final Pattern ZIP_ONLY = Pattern.compile('^\\d{5}(?:-\\d{4})?$');
    private static final Pattern CA_TAIL = Pattern.compile(
        '^(?:(.+?)\\s+)?([A-Za-z]{2})\\s+([A-Za-z]\\d[A-Za-z]\\s?\\d[A-Za-z]\\d)$');
    private static final Pattern AU_TAIL = Pattern.compile('^(?:(.+?)\\s+)?([A-Za-z]{2,3})\\.?\\s+(\\d{4})$');
    private static final Pattern UK_POSTCODE = Pattern.compile(
        '^(?:(.+?)\\s+)?([A-Za-z]{1,2}\\d[A-Za-z\\d]?\\s*\\d[A-Za-z]{2})$');
    private static final Pattern EU_TAIL = Pattern.compile('^((?:[A-Za-z]{1,2}[- ])?\\d{4,5})\\s*(?:-\\s*)?([^\\d,].*)$');
    private static final Pattern CITY_POSTAL = Pattern.compile('^([A-Za-z][A-Za-z .\'-]*?)\\s+(\\d{4,6})$');
    private static final Pattern POSTAL_ONLY = Pattern.compile('^(?:[A-Za-z]{1,2}[- ])?\\d{3,5}(?:[- ]\\d{3,4})?$');
    private static final Pattern NO_DIGITS = Pattern.compile('^[^\\d]+$');
    private static final Pattern HAS_DIGIT = Pattern.compile('\\d');
    private static final Pattern UNIT_SPLIT = Pattern.compile('^(.*\\d[^A-Za-z]*?)[\\s.\\-]+([A-Za-z][A-Za-z .\'-]*)$');
    private static final Pattern UNIT_WORDS = Pattern.compile(
        '(?i)\\b(suite|ste|floor|fl|unit|room|rm|level|bldg|building)\\b|#');

    public static Parts parse(String raw) {
        if (String.isBlank(raw)) return null;
        String s = TRAILING_NOTE.matcher(raw.trim()).replaceAll('');
        s = s.replace(EN_DASH, '-').replace(EM_DASH, '-').normalizeSpace();
        List<String> parts = new List<String>();
        for (String p : s.split('[,|;]')) if (String.isNotBlank(p)) parts.add(p.trim());
        if (parts.size() < 2) return null;

        String country = countryOf(last(parts));
        if (country != null) {
            parts.remove(parts.size() - 1);
        } else {
            Matcher tc = TRAILING_COUNTRY.matcher(last(parts));
            if (tc.matches()) {
                country = countryOf(tc.group(2));
                parts[parts.size() - 1] = tc.group(1);
            }
        }
        if (parts.isEmpty()) return null;
        // "..., Cape Town, South Africa, 8000": the country sits before the postcode.
        if (country == null && parts.size() >= 3
                && (matches(POSTAL_ONLY, last(parts)) || matches(UK_POSTCODE, last(parts)))
                && countryOf(parts[parts.size() - 2]) != null) {
            country = countryOf(parts.remove(parts.size() - 2));
        }

        String lastPart = last(parts);
        String prevPart = parts.size() >= 2 ? parts[parts.size() - 2] : '';
        String city, state, postal;
        Boolean usOk = country == null || country == 'United States';
        Matcher usTail = US_TAIL.matcher(lastPart);
        Matcher usNameTail = US_NAME_TAIL.matcher(lastPart);
        Matcher prevState = STATE_ONLY.matcher(prevPart);
        Matcher caTail = CA_TAIL.matcher(lastPart);
        Matcher auTail = AU_TAIL.matcher(lastPart);
        Matcher ukTail = UK_POSTCODE.matcher(lastPart);
        Matcher stateOnly = STATE_ONLY.matcher(lastPart);
        Matcher euTail = EU_TAIL.matcher(lastPart);
        Matcher cityPostal = CITY_POSTAL.matcher(lastPart);
        if (usOk && usTail.matches() && US_STATES.contains(usTail.group(2).toUpperCase())) {
            state = usTail.group(2).toUpperCase(); postal = usTail.group(3); city = usTail.group(1);
            pop(parts); country = 'United States';
        } else if (usOk && usNameTail.matches()) {
            state = STATE_NAMES.get(usNameTail.group(2).toLowerCase()); postal = usNameTail.group(3);
            city = usNameTail.group(1);
            pop(parts); country = 'United States';
        } else if (usOk && matches(ZIP_ONLY, lastPart) && parts.size() >= 3
                && STATE_NAMES.containsKey(prevPart.toLowerCase())) {
            postal = pop(parts); state = STATE_NAMES.get(pop(parts).toLowerCase()); country = 'United States';
        } else if (usOk && matches(ZIP_ONLY, lastPart) && parts.size() >= 2 && prevState.matches()
                && US_STATES.contains(prevState.group(2).toUpperCase())) {
            postal = pop(parts); pop(parts);
            state = prevState.group(2).toUpperCase(); city = prevState.group(1); country = 'United States';
        } else if ((country == null || country == 'Canada') && caTail.matches()
                && CA_PROVINCES.contains(caTail.group(2).toUpperCase())) {
            state = caTail.group(2).toUpperCase(); postal = caTail.group(3).toUpperCase(); city = caTail.group(1);
            pop(parts); country = 'Canada';
        } else if ((country == null || country == 'Australia') && auTail.matches()
                && AU_STATES.contains(auTail.group(2).toUpperCase())) {
            state = auTail.group(2).toUpperCase(); postal = auTail.group(3); city = auTail.group(1);
            pop(parts); country = 'Australia';
        } else if ((country == null || country == 'United Kingdom') && ukTail.matches()
                && !matches(POSTAL_ONLY, lastPart)) {
            postal = ukTail.group(2).toUpperCase(); city = ukTail.group(1);
            pop(parts); country = 'United Kingdom';
        } else if (usOk && stateOnly.matches() && US_STATES.contains(stateOnly.group(2).toUpperCase())
                && parts.size() >= 2) {
            state = stateOnly.group(2).toUpperCase(); city = stateOnly.group(1);
            pop(parts); country = 'United States';
        } else if (euTail.matches()) {
            postal = euTail.group(1); city = euTail.group(2).trim();
            pop(parts);
        } else if (cityPostal.matches()) {
            city = cityPostal.group(1).trim(); postal = cityPostal.group(2);
            pop(parts);
        } else if (matches(POSTAL_ONLY, lastPart) && parts.size() >= 3) {
            postal = pop(parts); city = pop(parts);
        } else if (matches(NO_DIGITS, lastPart) && parts.size() >= 3 && matches(POSTAL_ONLY, prevPart)) {
            city = pop(parts); postal = pop(parts);
        } else if (country != null && parts.size() >= 2 && matches(NO_DIGITS, lastPart)) {
            city = pop(parts);
        } else if (country != null && CITY_STATES.contains(country)) {
            city = country;
        }
        if (city == null && parts.size() >= 2 && (state != null || postal != null)) city = pop(parts);

        // "Suite 850 - Dallas": the unit belongs to the street.
        if (city != null && HAS_DIGIT.matcher(city).find()) {
            Matcher u = UNIT_SPLIT.matcher(city);
            if (!u.matches() || !UNIT_WORDS.matcher(u.group(1)).find()) return null;
            parts.add(stripChars(u.group(1), ' .-'));
            city = u.group(2);
        }
        if (city != null) {
            city = stripChars(city, ' -');
            // "75008 Paris France": a country name trailing the city.
            String low = city.toLowerCase();
            String best = null;
            for (String k : COUNTRIES.keySet()) {
                if (low.endsWith(' ' + k) && low.length() > k.length() + 1 && (best == null || k.length() > best.length())) {
                    best = k;
                }
            }
            if (best != null) {
                if (country == null) country = COUNTRIES.get(best);
                city = stripChars(city.substring(0, city.length() - best.length()), ' -,');
            }
            if (CITY_STATES.contains(city) && country == null) country = city;
            if (city.toUpperCase() == 'NY' && state == 'NY') city = 'New York';
        }
        if (parts.isEmpty() || String.isBlank(city) || (state == null && postal == null && country == null)) return null;
        if ((countryOf(city) != null && !CITY_STATES.contains(city))
                || HAS_DIGIT.matcher(city).find() || UNIT_WORDS.matcher(city).find()) return null;
        if (stripChars(city, '.').length() <= 3 && city.toUpperCase().equals(city)) return null;
        if (STATE_NAMES.containsKey(city.toLowerCase()) && state == null && postal != null
                && !matches(ZIP_ONLY, postal)) return null;

        Parts out = new Parts();
        out.street = String.join(parts, ', ');
        out.city = city;
        out.state = state;
        out.postalCode = postal;
        out.country = country;
        return out;
    }

    private static String countryOf(String s) {
        return s == null ? null : COUNTRIES.get(s.trim().toLowerCase().remove('.'));
    }

    private static Boolean matches(Pattern p, String s) {
        return s != null && p.matcher(s).matches();
    }

    private static String last(List<String> parts) {
        return parts[parts.size() - 1];
    }

    private static String pop(List<String> parts) {
        return parts.remove(parts.size() - 1);
    }

    private static String stripChars(String s, String chars) {
        if (s == null) return null;
        Integer start = 0;
        Integer stop = s.length();
        while (start < stop && chars.contains(s.substring(start, start + 1))) start++;
        while (stop > start && chars.contains(s.substring(stop - 1, stop))) stop--;
        return s.substring(start, stop);
    }
}
