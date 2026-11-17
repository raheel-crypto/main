/**
 * Rogo's online Terms & Conditions, fetched live (no stored copy to keep in step).
 * Most order forms incorporate them by link ("issued under and incorporates
 * Rogo's Terms & Conditions available at https://rogo.com/legal/terms-and-conditions"),
 * so the renewal notice, payment terms, subprocessor, publicity and AI terms of
 * those deals live there, not in the attached PDF.
 *
 * The extractor and the reviewer both get the page as plain text, labelled with
 * when it was fetched and the "last updated" date it shows. It is the CURRENT
 * version: a deal signed before that date may be governed by an earlier one, and
 * the prompts say so. When the fetch fails, extraction and review go on without
 * it and the reason is recorded - the terms then count as missing referenced terms.
 *
 * URL: Order_Form_Review_Setting__mdt.Default Standard_Terms_URL__c (blank = off).
 * Needs a Remote Site Setting for the host (Rogo_Website / Rogo_Website_WWW).
 * One fetch per transaction (cached); redirects followed up to three times.
 */
public with sharing class RogoStandardTerms {

    public class Terms {
        public String url;
        public String finalUrl;
        public String text;
        public String lastUpdated;
        public Datetime fetchedAt;
        public String failure;
        public String hash;
        public Integer spentMs = 0;
        public Boolean skipped = false;

        public Boolean ok() {
            return String.isNotBlank(text) && failure == null;
        }

        /** One line for the review's Sources_Sent__c. */
        public String sourceLine() {
            if (skipped) return null;
            if (!ok()) return 'NOT FETCHED: Rogo Terms & Conditions (' + url + ') - ' + failure;
            return 'Rogo Terms & Conditions (online, ' + finalUrl + '), fetched ' + fetchedAt.formatGmt('yyyy-MM-dd HH:mm')
                + ' UTC' + (lastUpdated == null ? '' : ', last updated ' + lastUpdated) + ', ' + text.length()
                + ' characters, sha256 ' + hash.left(12);
        }

        /**
         * The block the extractor and reviewer read. Null when the fetch was
         * skipped (tests, or no URL configured), so the request is unchanged.
         */
        public String promptBlock() {
            if (skipped) return null;
            String head = 'ROGO STANDARD TERMS & CONDITIONS (' + url + ')';
            if (!ok()) {
                return head + ' could not be fetched: ' + failure + '. Where a current-deal document incorporates '
                    + 'them by reference, their content is unknown: treat it as missing referenced terms.';
            }
            return head + ' - the CURRENT online version, fetched ' + fetchedAt.formatGmt('yyyy-MM-dd') + ' UTC'
                + (lastUpdated == null ? ' (the page shows no last-updated date)' : ', last updated ' + lastUpdated) + '.\n'
                + 'They govern a deal ONLY where a current-deal document incorporates Rogo\'s Terms & Conditions by '
                + 'reference (for example "issued under and incorporates Rogo\'s Terms & Conditions available at '
                + 'https://rogo.com/legal/terms-and-conditions"). Where the deal is on the customer\'s own agreement (an '
                + 'attached MSA or customer paper), these terms do not apply. The order form controls where the two '
                + 'conflict. A deal signed before the last-updated date may be governed by an earlier version: when a '
                + 'value depends on these terms and the deal predates that date, say so (an Issues entry, or a gap).\n'
                + 'Cite them as "Rogo Terms & Conditions (online) <section>".\n\n'
                + text;
        }
    }

    @TestVisible private static final Integer MIN_TEXT_CHARS = 2000;
    @TestVisible private static final Integer MAX_TEXT_CHARS = 150000;
    @TestVisible private static final Integer TIMEOUT_MS = 10000;
    // Tests opt in; otherwise no fetch runs in tests, so other tests' callout mocks are untouched.
    @TestVisible private static Boolean fetchInTests = false;
    @TestVisible private static Terms cached;

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

    public static String configuredUrl() {
        Order_Form_Review_Setting__mdt s = OrderFormReviewer.settings();
        return s == null ? null : s.Standard_Terms_URL__c;
    }

    /** The terms, fetched once per transaction. Never throws. */
    public static Terms get() {
        if (cached != null) return cached;
        Terms t = new Terms();
        t.url = configuredUrl();
        if (String.isBlank(t.url) || (Test.isRunningTest() && fetchInTests != true)) {
            t.skipped = true;
            cached = t;
            return t;
        }
        Long started = System.currentTimeMillis();
        try {
            String endpoint = t.url.trim();
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
        cached = t;
        return t;
    }

    /** Time the fetch used of the transaction's 120 seconds of callouts (0 when cached or skipped). */
    public static Integer spentMs() {
        return cached == null ? 0 : cached.spentMs;
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
