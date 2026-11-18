// =============================================================================
// Probe links from Salesforce: what does a plain fetch get back?
// =============================================================================
// For each URL: the status, every redirect, the content type and file name the
// server sends, the size, a preview of the text, and any links in the page that
// look like file downloads or data endpoints. Read-only; nothing is saved.
// Hosts need a Remote Site Setting (trust.rogo.ai has one: Rogo_Trust_Center).
//
// Run: sf apex run --target-org rogo --file scripts/apex/probeUrls.apex
// =============================================================================

List<String> URLS = new List<String>{
    'https://trust.rogo.ai?itemUid=e3fae2ca-94a9-416b-b577-5c90e382df57',
    'https://trust.rogo.ai/696deff1-2f4f-49b2-ae8e-b1166a4130de'
};
Pattern LINK = Pattern.compile('(?i)(https?:)?//?[A-Za-z0-9._~:/?#\\[\\]@!$&()*+,;=%-]*'
    + '(download|export|subprocessor|\\.csv|\\.pdf|\\.json|\\.xlsx|/api/)[A-Za-z0-9._~:/?#\\[\\]@!$&()*+,;=%-]*');

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
    System.debug('  Content-Type: ' + resp.getHeader('Content-Type') + ' | Content-Disposition: '
        + resp.getHeader('Content-Disposition'));
    Blob raw = resp.getBodyAsBlob();
    System.debug('  Size: ' + (raw == null ? 0 : raw.size()) + ' bytes');
    String ct = resp.getHeader('Content-Type') == null ? '' : resp.getHeader('Content-Type').toLowerCase();
    if (ct.contains('pdf') || ct.contains('octet-stream') || ct.contains('zip') || ct.contains('spreadsheet')) {
        System.debug('  (a file, not a page)');
        continue;
    }
    String body = resp.getBody();
    String visible = body.replaceAll('(?is)<(script|style)[^>]*>.*?</\\1>', ' ').replaceAll('<[^>]+>', ' ')
        .replaceAll('\\s+', ' ').trim();
    System.debug('  Visible text (' + visible.length() + ' chars): ' + visible.left(500));
    Set<String> seen = new Set<String>();
    Matcher m = LINK.matcher(body);
    while (m.find() && seen.size() < 25) {
        String l = m.group();
        if (l.length() > 8 && seen.add(l)) System.debug('  link: ' + l.left(250));
    }
    if (seen.isEmpty()) System.debug('  (no download / data links found in the page)');
}
