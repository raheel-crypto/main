/**
 * Wraps callouts to the Anthropic Messages API through the
 * `Anthropic_Claude` Named Credential. The Named Credential is expected
 * to inject the `x-api-key` header via its External Credential.
 */
public with sharing class AnthropicClient {

    @TestVisible private static final String NAMED_CREDENTIAL = 'Anthropic_Claude';
    @TestVisible private static final String DEFAULT_MODEL = 'claude-sonnet-4-6';
    @TestVisible private static final String API_VERSION = '2023-06-01';

    public class AnthropicException extends Exception {}

    /**
     * Calls the Messages API and returns the first text block from the response.
     * Throws AnthropicException on any HTTP or parsing failure.
     */
    public static String complete(String systemPrompt, String userPrompt, Integer maxTokens) {
        Map<String, Object> body = new Map<String, Object>{
            'model'      => DEFAULT_MODEL,
            'max_tokens' => maxTokens == null ? 4096 : maxTokens,
            'system'     => systemPrompt,
            'messages'   => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => userPrompt }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('anthropic-version', API_VERSION);
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            throw new AnthropicException('Anthropic callout failed: ' + e.getMessage());
        }

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new AnthropicException(
                'Anthropic API ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        } catch (Exception e) {
            throw new AnthropicException('Could not parse Anthropic response: ' + e.getMessage());
        }

        List<Object> content = (List<Object>) parsed.get('content');
        if (content == null || content.isEmpty()) {
            throw new AnthropicException('Anthropic response had no content blocks.');
        }
        Map<String, Object> first = (Map<String, Object>) content[0];
        if (first.get('type') != 'text') {
            throw new AnthropicException('First content block was not text: ' + first.get('type'));
        }
        return (String) first.get('text');
    }
}
