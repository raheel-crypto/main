// ARR_Hook_Callout.cls
// HMAC-signed @future callout to Hook on Vercel.
// Requires:
//   - Custom Metadata type: Hook_Config__mdt with fields Endpoint_URL__c (Text), HMAC_Secret__c (Text)
//   - Remote Site Setting allowing https://<your-hook-app>.vercel.app

public with sharing class ARR_Hook_Callout {

    @future(callout=true)
    public static void notifyAsync(Set<Id> accountIds) {
        Hook_Config__mdt cfg = Hook_Config__mdt.getInstance('Default');
        if (cfg == null) {
            System.debug(LoggingLevel.ERROR, 'Hook_Config__mdt "Default" not found');
            return;
        }

        for (Id accountId : accountIds) {
            String payload = JSON.serialize(new Map<String, Object>{
                'accountId' => String.valueOf(accountId),
                'orgId'     => UserInfo.getOrganizationId(),
                'firedAt'   => DateTime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
            });

            String signature = hmacSha256Hex(payload, cfg.HMAC_Secret__c);

            HttpRequest req = new HttpRequest();
            req.setEndpoint(cfg.Endpoint_URL__c + '/api/sf/opp-changed');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('X-Hook-Signature', signature);
            req.setBody(payload);
            req.setTimeout(30000);

            try {
                HttpResponse res = new Http().send(req);
                if (res.getStatusCode() >= 400) {
                    System.debug(LoggingLevel.ERROR,
                        'Hook callout failed (' + res.getStatusCode() + '): ' + res.getBody());
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Hook callout exception: ' + e.getMessage());
            }
        }
    }

    private static String hmacSha256Hex(String payload, String secret) {
        Blob mac = Crypto.generateMac('HmacSHA256', Blob.valueOf(payload), Blob.valueOf(secret));
        return EncodingUtil.convertToHex(mac);
    }
}
