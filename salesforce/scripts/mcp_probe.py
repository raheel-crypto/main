#!/usr/bin/env python3
"""Call a Salesforce hosted MCP server directly and show what it returns.

Usage:
    python3 scripts/mcp_probe.py <server-url> [tool-name] [json-arguments]

Examples:
    python3 scripts/mcp_probe.py https://rogo.my.salesforce.com/services/mcp/v1/HXLAccounts
    python3 scripts/mcp_probe.py <server-url> GetCloseReadinessapex_GetCloseReadiness \
        '{"inputs":[{"opportunityId":"006cv00000kSCgTAAW"}]}'

The access token comes from the Salesforce CLI (`sf org display --json`), so run
`sf org login web` first if you are not logged in. The script prints the
tools/list result (names plus the `_meta` block that carries the UI resource
link) and, when a tool name is given, the raw tools/call result with its
`_meta` keys so you can see whether `salesforce/uiMetadata` is present.
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request


def sf_auth():
    out = subprocess.run(
        ["sf", "org", "display", "--json"], capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        sys.exit("sf org display failed. Run `sf org login web` first.\n" + out.stderr)
    data = json.loads(out.stdout)["result"]
    return data["accessToken"], data["instanceUrl"]


def rpc(url, token, session_id, method, params, req_id):
    body = json.dumps(
        {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
    ).encode()
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read().decode()
            new_session = resp.headers.get("Mcp-Session-Id") or session_id
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} failed: HTTP {e.code}\n{e.read().decode()[:2000]}")
    # Streamable HTTP servers may answer as SSE ("data: {...}") or plain JSON.
    payload = None
    for line in raw.splitlines():
        if line.startswith("data:"):
            payload = json.loads(line[5:].strip())
    if payload is None:
        payload = json.loads(raw) if raw.strip() else {}
    return payload, new_session


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    url = sys.argv[1]
    tool = sys.argv[2] if len(sys.argv) > 2 else None
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}

    token, _ = sf_auth()
    init, session = rpc(
        url,
        token,
        None,
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {"extensions": {"io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}}},
            "clientInfo": {"name": "mcp-probe", "version": "0.1"},
        },
        1,
    )
    print("initialize:", json.dumps(init.get("result", init), indent=2)[:1500])
    if session:
        # notifications/initialized is a notification: no id, no response expected.
        try:
            rpc(url, token, session, "notifications/initialized", {}, None)
        except SystemExit:
            pass

    tools, session = rpc(url, token, session, "tools/list", {}, 2)
    print("\ntools/list:")
    for t in tools.get("result", {}).get("tools", []):
        print(" -", t.get("name"), "| _meta:", json.dumps(t.get("_meta")))

    if not tool:
        return
    result, _ = rpc(url, token, session, "tools/call", {"name": tool, "arguments": args}, 3)
    res = result.get("result", result)
    print("\ntools/call top-level keys:", list(res.keys()))
    meta = res.get("_meta") or {}
    print("_meta keys:", list(meta.keys()))
    ui = meta.get("salesforce/uiMetadata")
    print("salesforce/uiMetadata present:", ui is not None)
    if ui is not None:
        print("uiMetadata size (chars):", len(json.dumps(ui)))
    sc = res.get("structuredContent")
    print("structuredContent type:", type(sc).__name__)
    if isinstance(sc, dict):
        print("structuredContent keys:", list(sc.keys()))
    content = res.get("content") or []
    for c in content[:1]:
        text = c.get("text", "")
        print("first content block:", c.get("type"), "|", text[:300].replace("\n", " "))
    with open("mcp_probe_last_result.json", "w") as f:
        json.dump(result, f, indent=2)
    print("\nFull result saved to mcp_probe_last_result.json")


if __name__ == "__main__":
    main()
