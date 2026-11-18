/**
 * Rogo's published legal documents, fetched live (no stored copies to keep in step):
 * the online Terms & Conditions, the Data Processing Agreement and the Service Level
 * Agreement - plus the trust center's subprocessor list. Most order forms incorporate
 * the T&Cs by link ("issued under and incorporates Rogo's Terms & Conditions
 * available at https://rogo.com/legal/terms-and-conditions"), and the T&Cs in turn
 * incorporate the DPA and SLA, so renewal notice, payment, subprocessor, publicity
 * and AI terms of those deals live there, not in the attached PDF.
 *
 * The extractor and the reviewer both get the pages as plain text in one cached
 * system block, each labelled with when it was fetched and the "last updated" date
 * it shows. They are the CURRENT versions: a deal signed before that date may be
 * governed by an earlier one, and the block says so. A page that cannot be read is
 * recorded and skipped - extraction and review go on without it.
 *
 * URLs: Order_Form_Review_Setting__mdt.Default Standard_Terms_URL__c, several
 * separated by spaces (blank = off, the subprocessor list included). Only pages whose
 * text is in the HTML work. A #fragment is ignored. Each host needs a Remote Site
 * Setting (Rogo_Website, Rogo_Website_WWW, Rogo_Trust_Center). Fetched once per
 * transaction; redirects followed up to three times; at most BUDGET_MS of the
 * transaction's 120 callout seconds are spent here.
 *
 * The subprocessor list is not fetched: the trust center (trust.rogo.ai) draws it in
 * the browser. It is read from the static resource RogoSubprocessors, the CSV the
 * trust center exports ("Company Name","Purpose","Location","Additional Details",
 * "Created At"). To update it: download the CSV from the trust center, then Setup >
 * Static Resources > RogoSubprocessors > Edit > Choose File > Save. No deploy; the
 * next extraction or review reads it. Its upload date is recorded with each review.
 */
public with sharing class RogoStandardTerms {

    /** One fetched document. */
    public class Terms {
        public String name;
        public String url;
        public String finalUrl;
        public String text;
        public String lastUpdated;
        public Datetime fetchedAt;
        public String failure;
        public String hash;
        public Integer spentMs = 0;
        // Null for a page fetched online; otherwise where the text came from (the subprocessor list).
        public String origin;
        public Integer entries;

        public Boolean ok() {
            return String.isNotBlank(text) && failure == null;
        }

        /** One line for the review's Sources_Sent__c. */
        public String sourceLine() {
            if (!ok()) return 'NOT FETCHED: Rogo ' + name + ' (' + (origin == null ? url : origin) + ') - ' + failure;
            if (origin != null) {
                return 'Rogo ' + name + ' (' + origin + '), loaded ' + fetchedAt.formatGmt('yyyy-MM-dd HH:mm') + ' UTC, '
                    + entries + ' entries' + (lastUpdated == null ? '' : ', latest added ' + lastUpdated)
                    + ', sha256 ' + hash.left(12);
            }
            return 'Rogo ' + name + ' (online, ' + finalUrl + '), fetched ' + fetchedAt.formatGmt('yyyy-MM-dd HH:mm')
                + ' UTC' + (lastUpdated == null ? '' : ', last updated ' + lastUpdated) + ', ' + text.length()
                + ' characters, sha256 ' + hash.left(12);
        }
    }

    /** Every configured document, fetched (or not) in this transaction. */
    public class Library {
        public List<Terms> docs = new List<Terms>();
        public Boolean skipped = false;
        public Integer spentMs = 0;

        public List<String> sourceLines() {
            List<String> out = new List<String>();
            if (!skipped) for (Terms t : docs) out.add(t.sourceLine());
            return out;
        }

        /**
         * The block the extractor and reviewer read. Null when nothing is
         * configured (or in tests that did not ask), so the request is unchanged.
         */
        public String promptBlock() {
            if (skipped || docs.isEmpty()) return null;
            List<String> index = new List<String>();
            List<String> bodies = new List<String>();
            for (Terms t : docs) {
                if (t.ok() && t.origin != null) {
                    index.add('- ' + t.name + ' (' + t.url + '): the trust center\'s list as exported and loaded into '
                        + 'Salesforce on ' + t.fetchedAt.formatGmt('yyyy-MM-dd') + ' UTC, ' + t.entries + ' subprocessors'
                        + (t.lastUpdated == null ? '' : ', the latest added ' + t.lastUpdated) + '.');
                    bodies.add('=== ROGO ' + t.name.toUpperCase() + ' (' + t.url + ') ===\n' + t.text);
                } else if (t.ok()) {
                    index.add('- ' + t.name + ' (' + t.url + '): fetched ' + t.fetchedAt.formatGmt('yyyy-MM-dd') + ' UTC, '
                        + (t.lastUpdated == null ? 'the page shows no last-updated date' : 'last updated ' + t.lastUpdated)
                        + '.');
                    bodies.add('=== ROGO ' + t.name.toUpperCase() + ' (' + t.url + ') ===\n' + t.text);
                } else {
                    index.add('- ' + t.name + ' (' + t.url + '): could not be fetched (' + t.failure + '). Where a deal '
                        + 'incorporates it, its content is unknown: treat it as missing referenced terms.');
                }
            }
            return 'ROGO STANDARD TERMS - Rogo\'s published legal documents, fetched live (the subprocessor list '
                + 'from the trust center\'s export). These are the CURRENT versions:\n' + String.join(index, '\n') + '\n'
                + 'They govern a deal ONLY where its documents incorporate them: the Terms & Conditions where a '
                + 'current-deal document incorporates Rogo\'s Terms & Conditions by link (for example "issued under and '
                + 'incorporates Rogo\'s Terms & Conditions available at https://rogo.com/legal/terms-and-conditions"); '
                + 'the Data Processing Agreement, Service Level Agreement and subprocessor list where those governing '
                + 'terms incorporate them by reference. Where the deal is on a separately signed agreement (a Customer '
                + 'Agreement, "Terms & Conditions entered into by the parties on <date>") or on the customer\'s own '
                + 'paper, these documents do not govern it. The order form controls where it conflicts with them.\n'
                + 'A deal signed before a document\'s last-updated date (or any document with no date) may be governed '
                + 'by an earlier version: when a value depends on one of these documents, say so (an Issues entry, or a '
                + 'gap) rather than treating it as certain. A subprocessor list incorporated by reference stays '
                + '"By reference: <url>" in Sub_Processor_List - the published list is today\'s, not necessarily the '
                + 'one approved at signing. It shows the date each subprocessor was added: one added after a deal was '
                + 'signed was not on the list then, and one removed since is not shown. Use it to read a deal\'s '
                + 'subprocessor, location and AI-provider terms (which named providers are Rogo subprocessors, which '
                + 'are AI inference providers); it does not by itself change an extracted value, and a later addition '
                + 'is not a finding about the extraction.\n'
                + 'Cite them as "Rogo <document> (online) <section>".'
                + (bodies.isEmpty() ? '' : '\n\n' + String.join(bodies, '\n\n'));
        }
    }

    @TestVisible private static final Integer MIN_TEXT_CHARS = 1500;
    @TestVisible private static final Integer MAX_TEXT_CHARS = 150000;
    @TestVisible private static final Integer MAX_TOTAL_CHARS = 300000;
    @TestVisible private static final Integer TIMEOUT_MS = 8000;
    @TestVisible private static final Integer BUDGET_MS = 25000;
    // Tests opt in; otherwise no fetch runs in tests, so other tests' callout mocks are untouched.
    @TestVisible private static Boolean fetchInTests = false;
    @TestVisible private static Library cached;
    @TestVisible private static final String SUBPROCESSOR_RESOURCE = 'RogoSubprocessors';
    @TestVisible private static final String TRUST_CENTER = 'https://trust.rogo.ai';
    // Tests set these instead of reading the deployed static resource.
    @TestVisible private static String subprocessorCsv;
    @TestVisible private static Datetime subprocessorLoadedAt;
    private static final Map<String, Integer> MONTHS = new Map<String, Integer>{
        'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6, 'jul' => 7, 'aug' => 8, 'sep' => 9,
        'oct' => 10, 'nov' => 11, 'dec' => 12
    };

    private static final Pattern LAST_UPDATED = Pattern.compile(
        '(?i)(last\\s+updated|last\\s+revised|last\\s+modified|effective\\s+date|effective\\s+as\\s+of|updated)'
        + '\\s*(on)?\\s*[:\\-]?\\s*('
        + '[A-Z][a-z]+\\.?\\s+\\d{1,2}(st|nd|rd|th)?,?\\s+\\d{4}'
        + '|\\d{1,2}(st|nd|rd|th)?\\s+[A-Z][a-z]+\\.?,?\\s+\\d{4}'
        + '|\\d{4}-\\d{2}-\\d{2}'
        + '|\\d{1,2}/\\d{1,2}/\\d{2,4})');
    private static final Set<String> BLOCK_TAGS = new Set<String>{
        'p', 'br', 'li', 'ul', 'ol', 'div', 'section', 'article', 'tr', 'table', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'blockquote', 'header', 'footer', 'main'
    };
    private static final List<String> DROPPED_ELEMENTS = new List<String>{ 'script', 'style', 'noscript', 'svg', 'head', 'template' };
    private static final Map<String, String> NAMES = new Map<String, String>{
        'terms-and-conditions' => 'Terms & Conditions',
        'data-processing-agreement' => 'Data Processing Agreement',
        'service-level-agreement' => 'Service Level Agreement'
    };

    /** The configured URLs, in order, without #fragments. */
    public static List<String> configuredUrls() {
        Order_Form_Review_Setting__mdt s = OrderFormReviewer.settings();
        List<String> out = new List<String>();
        String raw = s == null ? null : s.Standard_Terms_URL__c;
        if (String.isBlank(raw)) return out;
        for (String part : raw.split('[\\s,;]+')) {
            String u = part.trim();
            if (u.contains('#')) u = u.substringBefore('#');
            if (u.startsWithIgnoreCase('http') && !out.contains(u)) out.add(u);
        }
        return out;
    }

    /** Every configured document, fetched once per transaction. Never throws. */
    public static Library library() {
        if (cached != null) return cached;
        Library lib = new Library();
        List<String> urls = configuredUrls();
        if (urls.isEmpty() || (Test.isRunningTest() && fetchInTests != true)) {
            lib.skipped = true;
            cached = lib;
            return lib;
        }
        Integer totalChars = 0;
        for (String u : urls) {
            Terms t;
            if (lib.spentMs >= BUDGET_MS) {
                t = new Terms();
                t.url = u;
                t.name = nameFor(u);
                t.fetchedAt = System.now();
                t.failure = 'skipped: the fetch time budget was used up by the documents before it';
            } else {
                t = fetch(u);
            }
            if (t.ok() && totalChars + t.text.length() > MAX_TOTAL_CHARS) {
                t.text = null;
                t.failure = 'skipped: the documents before it already fill the size budget';
            }
            if (t.ok()) totalChars += t.text.length();
            lib.spentMs += t.spentMs;
            lib.docs.add(t);
        }
        Terms subprocessors = subprocessorList();
        if (subprocessors.ok() && totalChars + subprocessors.text.length() > MAX_TOTAL_CHARS) {
            subprocessors.text = null;
            subprocessors.failure = 'skipped: the documents before it already fill the size budget';
        }
        lib.docs.add(subprocessors);
        cached = lib;
        return lib;
    }

    /** Rogo's subprocessor list, from the static resource holding the trust center's CSV export. Never throws. */
    @TestVisible
    private static Terms subprocessorList() {
        Terms t = new Terms();
        t.name = 'Subprocessor List';
        t.url = TRUST_CENTER;
        t.finalUrl = TRUST_CENTER;
        t.origin = 'trust center export, Salesforce static resource ' + SUBPROCESSOR_RESOURCE;
        t.fetchedAt = System.now();
        try {
            String csv = subprocessorCsv;
            Datetime loaded = subprocessorLoadedAt;
            if (csv == null) {
                List<StaticResource> res = [SELECT Body, LastModifiedDate FROM StaticResource
                                            WHERE Name = :SUBPROCESSOR_RESOURCE LIMIT 1];
                if (res.isEmpty()) {
                    t.failure = 'there is no static resource named ' + SUBPROCESSOR_RESOURCE;
                    return t;
                }
                csv = res[0].Body.toString();
                loaded = res[0].LastModifiedDate;
            }
            if (loaded != null) t.fetchedAt = loaded;
            String bom = String.fromCharArray(new List<Integer>{ 65279 });
            if (csv.startsWith(bom)) csv = csv.substring(1);
            List<List<String>> rows = parseCsv(csv.left(MAX_TEXT_CHARS));
            if (rows.size() < 2 || rows[0].size() < 2) {
                t.failure = 'the static resource is not the trust center\'s CSV export (it needs a header row and at '
                    + 'least one subprocessor)';
                return t;
            }
            List<String> header = new List<String>();
            Integer addedCol = -1;
            for (String h : rows[0]) {
                String label = clean(h);
                if (label.equalsIgnoreCase('Created At') || label.equalsIgnoreCase('Date Added')) {
                    addedCol = header.size();
                    label = 'Added';
                }
                header.add(label);
            }
            List<String> lines = new List<String>();
            Date latest;
            for (Integer r = 1; r < rows.size(); r++) {
                List<String> row = rows[r];
                List<String> parts = new List<String>();
                for (Integer c = 0; c < row.size(); c++) {
                    String v = clean(row[c]);
                    if (String.isBlank(v)) continue;
                    parts.add(c == 0 || c >= header.size() || String.isBlank(header[c]) ? v : header[c] + ': ' + v);
                }
                lines.add('- ' + String.join(parts, ' | '));
                Date added = addedCol >= 0 && addedCol < row.size() ? longDate(clean(row[addedCol])) : null;
                if (added != null && (latest == null || added > latest)) {
                    latest = added;
                    t.lastUpdated = clean(row[addedCol]);
                }
            }
            t.entries = lines.size();
            t.text = 'Rogo\'s subprocessors (' + t.entries + '), as listed on the trust center (' + TRUST_CENTER
                + ') and loaded into Salesforce on ' + t.fetchedAt.formatGmt('yyyy-MM-dd') + '. "Added" is the date '
                + 'each was added to the list; one removed before then is not shown.\n' + String.join(lines, '\n');
            t.hash = OrderFormReviewer.sha256(t.text);
        } catch (Exception e) {
            t.text = null;
            t.failure = 'the static resource ' + SUBPROCESSOR_RESOURCE + ' could not be read: ' + e.getMessage();
        }
        return t;
    }

    /** Rows of a CSV: quoted fields may hold commas, doubled quotes and line breaks; blank rows are dropped. */
    @TestVisible
    private static List<List<String>> parseCsv(String csv) {
        List<List<String>> rows = new List<List<String>>();
        List<String> row = new List<String>();
        String field = '';
        Boolean quoted = false;
        Integer i = 0;
        Integer n = csv.length();
        while (i < n) {
            String c = csv.substring(i, i + 1);
            if (quoted) {
                if (c == '"') {
                    if (i + 1 < n && csv.substring(i + 1, i + 2) == '"') {
                        field += '"';
                        i += 2;
                    } else {
                        quoted = false;
                        i++;
                    }
                    continue;
                }
                Integer q = csv.indexOf('"', i);
                if (q < 0) q = n;
                field += csv.substring(i, q);
                i = q;
                continue;
            }
            if (c == '"') {
                quoted = true;
                i++;
            } else if (c == ',') {
                row.add(field);
                field = '';
                i++;
            } else if (c == '\n' || c == '\r') {
                row.add(field);
                field = '';
                if (!blankRow(row)) rows.add(row);
                row = new List<String>();
                i += (c == '\r' && i + 1 < n && csv.substring(i + 1, i + 2) == '\n') ? 2 : 1;
            } else {
                Integer stop = n;
                for (String special : new List<String>{ ',', '"', '\n', '\r' }) {
                    Integer k = csv.indexOf(special, i);
                    if (k >= 0 && k < stop) stop = k;
                }
                field += csv.substring(i, stop);
                i = stop;
            }
        }
        row.add(field);
        if (!blankRow(row)) rows.add(row);
        return rows;
    }

    private static Boolean blankRow(List<String> row) {
        for (String v : row) if (String.isNotBlank(v)) return false;
        return true;
    }

    private static String clean(String v) {
        return v == null ? '' : v.replaceAll('\\s+', ' ').trim();
    }

    /** "May 15, 2025", "15 May 2025" or "2025-05-15" as a Date; null otherwise. */
    @TestVisible
    private static Date longDate(String v) {
        if (String.isBlank(v)) return null;
        Matcher iso = Pattern.compile('^(\\d{4})-(\\d{2})-(\\d{2})').matcher(v);
        if (iso.find()) {
            return Date.newInstance(Integer.valueOf(iso.group(1)), Integer.valueOf(iso.group(2)), Integer.valueOf(iso.group(3)));
        }
        Matcher mdy = Pattern.compile('^([A-Za-z]{3})[A-Za-z]*\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})').matcher(v);
        Matcher dmy = Pattern.compile('^(\\d{1,2})\\s+([A-Za-z]{3})[A-Za-z]*\\.?,?\\s+(\\d{4})').matcher(v);
        String month;
        String day;
        String year;
        if (mdy.find()) {
            month = mdy.group(1);
            day = mdy.group(2);
            year = mdy.group(3);
        } else if (dmy.find()) {
            day = dmy.group(1);
            month = dmy.group(2);
            year = dmy.group(3);
        } else {
            return null;
        }
        Integer m = MONTHS.get(month.toLowerCase());
        return m == null ? null : Date.newInstance(Integer.valueOf(year), m, Integer.valueOf(day));
    }

    /** Time the fetches used of the transaction's 120 seconds of callouts (0 when cached-free or skipped). */
    public static Integer spentMs() {
        return cached == null ? 0 : cached.spentMs;
    }

    @TestVisible
    private static String nameFor(String url) {
        String path = url.substringAfter('://');
        String host = path.contains('/') ? path.substringBefore('/') : path;
        if (host.startsWithIgnoreCase('trust.')) return 'Trust Center (published subprocessor list)';
        String slug = path.contains('/') ? path.substringAfterLast('/') : '';
        if (NAMES.containsKey(slug.toLowerCase())) return NAMES.get(slug.toLowerCase());
        if (String.isBlank(slug)) return host;
        List<String> words = new List<String>();
        for (String w : slug.split('[-_]+')) if (String.isNotBlank(w)) words.add(w.capitalize());
        return String.join(words, ' ');
    }

    private static Terms fetch(String url) {
        Terms t = new Terms();
        t.url = url;
        t.name = nameFor(url);
        Long started = System.currentTimeMillis();
        try {
            String endpoint = url;
            HttpResponse resp;
            for (Integer hop = 0; hop < 4; hop++) {
                HttpRequest req = new HttpRequest();
                req.setEndpoint(endpoint);
                req.setMethod('GET');
                req.setTimeout(TIMEOUT_MS);
                req.setHeader('Accept', 'text/html');
                req.setHeader('User-Agent', 'Rogo-Salesforce-OrderForms/1.0');
                resp = new Http().send(req);
                Integer code = resp.getStatusCode();
                String location = resp.getHeader('Location');
                if (code >= 300 && code < 400 && String.isNotBlank(location)) {
                    endpoint = absolute(endpoint, location);
                    continue;
                }
                break;
            }
            t.finalUrl = endpoint;
            if (resp.getStatusCode() != 200) {
                t.failure = 'HTTP ' + resp.getStatusCode() + ' from ' + endpoint;
            } else {
                String text = toText(resp.getBody());
                if (text.length() < MIN_TEXT_CHARS) {
                    t.failure = 'the page returned only ' + text.length() + ' characters of text (it may need a '
                        + 'browser to render)';
                } else {
                    t.text = text.length() > MAX_TEXT_CHARS ? text.left(MAX_TEXT_CHARS) : text;
                    t.lastUpdated = lastUpdated(t.text);
                    t.hash = OrderFormReviewer.sha256(t.text);
                }
            }
        } catch (Exception e) {
            t.failure = e.getMessage();
        }
        t.spentMs = (System.currentTimeMillis() - started).intValue();
        t.fetchedAt = System.now();
        return t;
    }

    @TestVisible
    private static String absolute(String base, String location) {
        if (location.startsWith('http://') || location.startsWith('https://')) return location;
        Integer schemeEnd = base.indexOf('://');
        Integer hostEnd = base.indexOf('/', schemeEnd + 3);
        String origin = hostEnd < 0 ? base : base.substring(0, hostEnd);
        return origin + (location.startsWith('/') ? location : '/' + location);
    }

    @TestVisible
    private static String lastUpdated(String text) {
        Matcher m = LAST_UPDATED.matcher(text.left(20000));
        return m.find() ? m.group(3) : null;
    }

    /** Plain text of an HTML page: scripts, styles and the head dropped, block tags as line breaks, entities decoded. */
    @TestVisible
    private static String toText(String html) {
        if (String.isBlank(html)) return '';
        String s = html;
        for (String el : DROPPED_ELEMENTS) s = dropElement(s, el);
        List<String> out = new List<String>();
        Integer pos = 0;
        Integer n = s.length();
        while (pos < n) {
            Integer lt = s.indexOf('<', pos);
            if (lt < 0) {
                out.add(s.substring(pos));
                break;
            }
            if (lt > pos) out.add(s.substring(pos, lt));
            Integer gt = s.indexOf('>', lt);
            if (gt < 0) break;
            String tag = s.substring(lt + 1, gt).trim().toLowerCase().removeStart('/');
            Integer cut = tag.length();
            for (String sep : new List<String>{ ' ', '/', '\n', '\t' }) {
                Integer i = tag.indexOf(sep);
                if (i >= 0 && i < cut) cut = i;
            }
            out.add(BLOCK_TAGS.contains(tag.left(cut)) ? '\n' : ' ');
            pos = gt + 1;
        }
        String text = decode(String.join(out, ''));
        text = text.replaceAll('[ \\t\\x0B\\f\\r]+', ' ').replaceAll(' *\\n *', '\n').replaceAll('\\n{3,}', '\n\n');
        return text.trim();
    }

    private static String dropElement(String s, String el) {
        String lower = s.toLowerCase();
        List<String> parts = new List<String>();
        Integer pos = 0;
        while (true) {
            Integer open = lower.indexOf('<' + el, pos);
            if (open < 0) break;
            Integer close = lower.indexOf('</' + el, open);
            Integer stop = close < 0 ? -1 : lower.indexOf('>', close);
            parts.add(s.substring(pos, open));
            if (stop < 0) {
                pos = s.length();
                break;
            }
            pos = stop + 1;
        }
        parts.add(s.substring(Math.min(pos, s.length())));
        return String.join(parts, ' ');
    }

    private static String decode(String s) {
        String t = s.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')
            .replace('&quot;', '"').replace('&#39;', '\'').replace('&apos;', '\'').replace('&rsquo;', '\'')
            .replace('&lsquo;', '\'').replace('&ldquo;', '"').replace('&rdquo;', '"').replace('&mdash;', '-')
            .replace('&ndash;', '-').replace('&sect;', '§').replace('&hellip;', '...');
        Matcher m = Pattern.compile('&#(x?[0-9a-fA-F]{1,6});').matcher(t);
        List<String> parts = new List<String>();
        Integer pos = 0;
        while (m.find()) {
            parts.add(t.substring(pos, m.start()));
            String code = m.group(1);
            Integer cp;
            try {
                cp = code.startsWithIgnoreCase('x') ? hex(code.substring(1)) : Integer.valueOf(code);
            } catch (Exception e) {
                cp = null;
            }
            parts.add(cp == null || cp <= 0 ? ' ' : String.fromCharArray(new List<Integer>{ cp }));
            pos = m.end();
        }
        parts.add(t.substring(pos));
        return String.join(parts, '');
    }

    private static Integer hex(String h) {
        Integer v = 0;
        for (Integer i = 0; i < h.length(); i++) {
            v = v * 16 + '0123456789abcdef'.indexOf(h.substring(i, i + 1).toLowerCase());
        }
        return v;
    }
}
