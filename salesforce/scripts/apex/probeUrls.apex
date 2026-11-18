// =============================================================================
// Probe links from Salesforce: what does a plain fetch get back?
// =============================================================================
// For each URL: the status, every redirect, the content type and file name the
// server sends, the size, a preview of the visible text, and any addresses in
// the page that look like file downloads or data endpoints. Read-only; nothing
// is saved. No regular expressions over the page (a large page exceeds Apex's
// regex limit) - it is scanned with plain string searches.
// Hosts need a Remote Site Setting (trust.rogo.ai has one: Rogo_Trust_Center).
//
// Run: sf apex run --target-org rogo --file scripts/apex/probeUrls.apex
// =============================================================================

List<String> URLS = new List<String>{
    'https://trust.rogo.ai?itemUid=e3fae2ca-94a9-416b-b577-5c90e382df57'
};
List<String> KEYWORDS = new List<String>{ 'download', 'export', 'subprocessor', '.csv', '.pdf', '.json', '.xlsx',
    '/api/', 'item', 'document', 'file', 'storage', 'amazonaws', 'cloudfront' };
String STOP_CHARS = '"\'<> \\\n\r\t)`';

for (String start : URLS) {
    System.debug('==================== ' + start);
    String endpoint = start;
    HttpResponse resp;
    try {
        for (Integer hop = 0; hop < 5; hop++) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setTimeout(10000);
            req.setHeader('User-Agent', 'Rogo-Salesforce-OrderForms/1.0');
            resp = new Http().send(req);
            String location = resp.getHeader('Location');
            System.debug('  ' + resp.getStatusCode() + ' ' + endpoint + (location == null ? '' : '  -> ' + location));
            if (resp.getStatusCode() >= 300 && resp.getStatusCode() < 400 && location != null) {
                endpoint = location.startsWith('http') ? location
                    : endpoint.substringBefore('://') + '://' + endpoint.substringAfter('://').substringBefore('/') + location;
                continue;
            }
            break;
        }
    } catch (Exception e) {
        System.debug('  FAILED: ' + e.getMessage());
        continue;
    }
    String ct = resp.getHeader('Content-Type') == null ? '' : resp.getHeader('Content-Type');
    System.debug('  Content-Type: ' + ct + ' | Content-Disposition: ' + resp.getHeader('Content-Disposition'));
    Blob raw = resp.getBodyAsBlob();
    System.debug('  Size: ' + (raw == null ? 0 : raw.size()) + ' bytes');
    String lower = ct.toLowerCase();
    if (lower.contains('pdf') || lower.contains('octet-stream') || lower.contains('zip') || lower.contains('spreadsheet')) {
        System.debug('  (a file, not a page)');
        continue;
    }
    String body = resp.getBody();
    if (body.length() > 600000) body = body.left(600000);

    // Visible text: drop <script>/<style> blocks, then tags - plain searches only.
    String low = body.toLowerCase();
    List<String> parts = new List<String>();
    Integer pos = 0;
    while (pos < body.length()) {
        Integer s1 = low.indexOf('<script', pos);
        Integer s2 = low.indexOf('<style', pos);
        Integer s = (s1 < 0) ? s2 : (s2 < 0 ? s1 : Math.min(s1, s2));
        if (s < 0) { parts.add(body.substring(pos)); break; }
        parts.add(body.substring(pos, s));
        Integer e1 = low.indexOf(s == s1 ? '</script>' : '</style>', s);
        if (e1 < 0) break;
        pos = e1 + (s == s1 ? 9 : 8);
    }
    String noScripts = String.join(parts, ' ');
    List<String> textParts = new List<String>();
    pos = 0;
    while (pos < noScripts.length()) {
        Integer lt = noScripts.indexOf('<', pos);
        if (lt < 0) { textParts.add(noScripts.substring(pos)); break; }
        textParts.add(noScripts.substring(pos, lt));
        Integer gt = noScripts.indexOf('>', lt);
        if (gt < 0) break;
        textParts.add(' ');
        pos = gt + 1;
    }
    String visible = String.join(textParts, '').normalizeSpace();
    System.debug('  Visible text (' + visible.length() + ' chars): ' + visible.left(500));

    // Addresses in the page (including inside its code) that look like files or data endpoints.
    Set<String> seen = new Set<String>();
    pos = 0;
    while (seen.size() < 30) {
        Integer h = body.indexOf('http', pos);
        if (h < 0) break;
        Integer e = h;
        while (e < body.length() && e - h < 400 && !STOP_CHARS.contains(body.substring(e, e + 1))) e++;
        String url = body.substring(h, e);
        String ul = url.toLowerCase();
        if (url.startsWith('http') && url.contains('://')) {
            for (String k : KEYWORDS) {
                if (ul.contains(k)) { if (seen.add(url)) System.debug('  address: ' + url.left(300)); break; }
            }
        }
        pos = e + 1;
    }
    if (seen.isEmpty()) System.debug('  (no file / data addresses found in the page)');

    // Where the page (and the data embedded in it) mentions subprocessors: up to 12 excerpts.
    Integer shown = 0;
    pos = 0;
    while (shown < 12) {
        Integer at = low.indexOf('subprocessor', pos);
        if (at < 0) break;
        String excerpt = body.substring(Math.max(0, at - 120), Math.min(body.length(), at + 280));
        System.debug('  excerpt ' + (shown + 1) + ': ' + excerpt.replace('\n', ' ').replace('\r', ' '));
        shown++;
        pos = at + 280;
    }
    System.debug('  Mentions: ' + (low.countMatches('.pdf')) + ' x ".pdf", ' + low.countMatches('download')
        + ' x "download", ' + low.countMatches('subprocessor') + ' x "subprocessor"');
}
