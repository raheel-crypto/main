/**
 * Rogo's published legal documents, fetched live (no stored copies to keep in step):
 * the online Terms & Conditions, the Data Processing Agreement, the Service Level
 * Agreement and the trust center's subprocessor list. Most order forms incorporate
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
 * separated by spaces (blank = off). Only pages whose text is in the HTML work: the
 * trust center (trust.rogo.ai) draws its subprocessor list in the browser, so
 * Salesforce sees just its headings - it is left out. A #fragment is ignored. Each host needs a
 * Remote Site Setting (Rogo_Website, Rogo_Website_WWW, Rogo_Trust_Center).
 * Fetched once per transaction; redirects followed up to three times; at most
 * BUDGET_MS of the transaction's 120 callout seconds are spent here.
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

        public Boolean ok() {
            return String.isNotBlank(text) && failure == null;
        }

        /** One line for the review's Sources_Sent__c. */
        public String sourceLine() {
            if (!ok()) return 'NOT FETCHED: Rogo ' + name + ' (' + url + ') - ' + failure;
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
                if (t.ok()) {
                    index.add('- ' + t.name + ' (' + t.url + '): fetched ' + t.fetchedAt.formatGmt('yyyy-MM-dd') + ' UTC, '
                        + (t.lastUpdated == null ? 'the page shows no last-updated date' : 'last updated ' + t.lastUpdated)
                        + '.');
                    bodies.add('=== ROGO ' + t.name.toUpperCase() + ' (' + t.url + ') ===\n' + t.text);
                } else {
                    index.add('- ' + t.name + ' (' + t.url + '): could not be fetched (' + t.failure + '). Where a deal '
                        + 'incorporates it, its content is unknown: treat it as missing referenced terms.');
                }
            }
            return 'ROGO STANDARD TERMS - Rogo\'s published legal documents, fetched live. These are the CURRENT '
                + 'versions:\n' + String.join(index, '\n') + '\n'
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
                + 'one approved at signing.\n'
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
        cached = lib;
        return lib;
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
