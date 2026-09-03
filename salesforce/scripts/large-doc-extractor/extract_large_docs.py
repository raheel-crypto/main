#!/usr/bin/env python3
"""
extract_large_docs.py

Extract order-form / MSA data from documents too large for Salesforce Apex
(> ~10 MB, up to Anthropic's 32 MB PDF limit), off-platform, using the
Anthropic Files API. Apex can't even load a file that big into its 12 MB heap,
so these have to be processed here instead.

For each Opportunity Id you pass, it:
  1. finds the documents on the Opp (+ its Base Opportunity) via the SF API,
  2. downloads each supported file (PDF / PNG / JPG / GIF / WEBP) - streamed,
     no heap limit,
  3. uploads each to the Anthropic Files API and runs the SAME extraction
     prompt (staticresources/OrderFormPrompt.txt) via the Messages API,
  4. --write: POSTs the raw Anthropic response to the Salesforce REST endpoint
     /services/apexrest/OrderFormExtractionFromResponse, which runs your normal
     field mapping and inserts an Order_Form_Extraction__c (identical to an
     in-platform row). --dry-run (default): just prints the extracted JSON.

Auth:
  * Salesforce - uses your sf CLI session. Pass --target-org (default: rogo).
  * Anthropic  - reads ANTHROPIC_API_KEY from the environment.

Setup (once):
  pip install -r requirements.txt
  export ANTHROPIC_API_KEY=sk-ant-...

Usage:
  # dry run - print what would be extracted
  python3 extract_large_docs.py 006V400000JY2pFIAT 006cv00000enYG2AAM
  # write the OFE rows for real
  python3 extract_large_docs.py --write 006V400000JY2pFIAT 006cv00000enYG2AAM
"""

import argparse
import io
import json
import os
import subprocess
import sys
from pathlib import Path

import requests
from anthropic import Anthropic

API_VERSION = "v62.0"

# Match the in-platform pipeline's model so these extractions are consistent
# with the ~1,300 done in Apex. Override with --model if you ever change it.
DEFAULT_MODEL = "claude-sonnet-4-6"
MAX_TOKENS = 8192
# Anthropic's PDF ceiling is 32 MB; stop before that with a little headroom.
MAX_FILE_BYTES = 31 * 1024 * 1024

# Extension -> (anthropic content-block type, mime type). Mirrors Apex getMediaType.
MEDIA = {
    "pdf": ("document", "application/pdf"),
    "png": ("image", "image/png"),
    "jpg": ("image", "image/jpeg"),
    "jpeg": ("image", "image/jpeg"),
    "gif": ("image", "image/gif"),
    "webp": ("image", "image/webp"),
}

# Resolve the prompt from the repo (…/salesforce/force-app/.../OrderFormPrompt.txt).
PROMPT_PATH = (
    Path(__file__).resolve().parents[2]
    / "force-app/main/default/staticresources/OrderFormPrompt.txt"
)


def sf_session(target_org):
    """Return (instance_url, access_token) from the sf CLI.

    `sf org display` returns the CACHED access token without refreshing it, so
    it's often expired (401). We use the sfdxAuthUrl (a refresh token) to mint a
    fresh access token, falling back to the cached one if it isn't available.
    """
    out = subprocess.run(
        ["sf", "org", "display", "--target-org", target_org, "--verbose", "--json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"sf org display failed:\n{out.stderr or out.stdout}")
    result = json.loads(out.stdout)["result"]
    instance_url = result["instanceUrl"]

    auth_url = result.get("sfdxAuthUrl")
    if auth_url and auth_url.startswith("force://"):
        # force://<clientId>:<clientSecret>:<refreshToken>@<instanceUrl>
        creds = auth_url[len("force://"):].split("@", 1)[0]
        client_id, client_secret, refresh_token = creds.split(":", 2)
        r = requests.post(
            f"{instance_url}/services/oauth2/token",
            data={
                "grant_type": "refresh_token",
                "client_id": client_id or "PlatformCLI",
                "client_secret": client_secret,
                "refresh_token": refresh_token,
            }, timeout=60,
        )
        r.raise_for_status()
        return instance_url, r.json()["access_token"]

    # No refresh token available - use the cached access token as-is.
    return instance_url, result["accessToken"]


def sf_query(instance_url, token, soql):
    r = requests.get(
        f"{instance_url}/services/data/{API_VERSION}/query",
        headers={"Authorization": f"Bearer {token}"},
        params={"q": soql}, timeout=60,
    )
    r.raise_for_status()
    return r.json()["records"]


def docs_for_opp(instance_url, token, opp_id):
    """Every document on the Opp + its Base Opportunity (dedup, opp first)."""
    opps = sf_query(
        instance_url, token,
        f"SELECT Id, Name, Type, CloseDate, Base_Opportunity__c "
        f"FROM Opportunity WHERE Id = '{opp_id}'",
    )
    if not opps:
        return None, []
    opp = opps[0]
    entity_ids = [opp_id] + ([opp["Base_Opportunity__c"]] if opp.get("Base_Opportunity__c") else [])
    in_list = ",".join(f"'{e}'" for e in entity_ids)
    links = sf_query(
        instance_url, token,
        "SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, "
        "ContentDocument.ContentSize, ContentDocument.LatestPublishedVersionId "
        f"FROM ContentDocumentLink WHERE LinkedEntityId IN ({in_list})",
    )
    seen, docs = set(), []
    for lk in links:
        cd_id = lk["ContentDocumentId"]
        if cd_id in seen:
            continue
        seen.add(cd_id)
        cd = lk["ContentDocument"]
        docs.append({
            "contentDocumentId": cd_id,
            "title": cd["Title"],
            "ext": (cd.get("FileExtension") or "").lower(),
            "size": cd.get("ContentSize") or 0,
            "versionId": cd["LatestPublishedVersionId"],
        })
    return opp, docs


def download(instance_url, token, version_id):
    r = requests.get(
        f"{instance_url}/services/data/{API_VERSION}/sobjects/ContentVersion/{version_id}/VersionData",
        headers={"Authorization": f"Bearer {token}"}, timeout=300,
    )
    r.raise_for_status()
    return r.content


def deal_context(opp):
    return (
        "DEAL CONTEXT:\n"
        f"- Opportunity Name: {opp.get('Name') or 'unknown'}\n"
        f"- Opportunity Type: {opp.get('Type') or 'unspecified'}\n"
        f"- Close Date: {opp.get('CloseDate') or 'unknown'}\n"
        "Extract the CURRENT deal. Treat any parent-contract documents as context only. "
        "Return ONLY the JSON object described in the system prompt."
    )


def extract_one(client, model, system_prompt, opp, docs, instance_url, token):
    blocks, used_doc_ids = [], []
    for d in docs:
        media = MEDIA.get(d["ext"])
        if not media:
            print(f"    skip (unsupported .{d['ext']}): {d['title']}")
            continue
        if d["size"] and d["size"] > MAX_FILE_BYTES:
            print(f"    skip (>{MAX_FILE_BYTES} bytes, over Anthropic's limit): {d['title']}")
            continue
        block_type, mime = media
        print(f"    downloading + uploading: {d['title']} ({d['size']} bytes, .{d['ext']})")
        data = download(instance_url, token, d["versionId"])
        uploaded = client.files.upload(file=(f"{d['title']}.{d['ext']}", io.BytesIO(data), mime))
        blocks.append({"type": block_type, "source": {"type": "file", "file_id": uploaded.id}})
        used_doc_ids.append(d["contentDocumentId"])

    if not blocks:
        return None, [], None

    blocks.append({"type": "text", "text": deal_context(opp)})
    raw = client.messages.with_raw_response.create(
        model=model, max_tokens=MAX_TOKENS, system=system_prompt,
        messages=[{"role": "user", "content": blocks}],
    )
    return raw.text, used_doc_ids, raw.parse()


def write_back(instance_url, token, opp_id, doc_ids, response_body):
    r = requests.post(
        f"{instance_url}/services/apexrest/OrderFormExtractionFromResponse",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        data=json.dumps({
            "opportunityId": opp_id,
            "contentDocumentIds": doc_ids,
            "responseBody": response_body,
        }), timeout=120,
    )
    r.raise_for_status()
    return r.json()


def main():
    ap = argparse.ArgumentParser(description="Extract oversized order forms via the Anthropic Files API.")
    ap.add_argument("opportunity_ids", nargs="+", help="Salesforce Opportunity Ids")
    ap.add_argument("--target-org", default="rogo", help="sf CLI org alias (default: rogo)")
    ap.add_argument("--model", default=DEFAULT_MODEL, help=f"Anthropic model (default: {DEFAULT_MODEL})")
    ap.add_argument("--write", action="store_true",
                    help="Insert the OFE via the SF REST endpoint (default is a dry run that only prints)")
    args = ap.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Set ANTHROPIC_API_KEY in your environment first.")
    if not PROMPT_PATH.exists():
        sys.exit(f"Prompt not found at {PROMPT_PATH}")

    system_prompt = PROMPT_PATH.read_text()
    instance_url, token = sf_session(args.target_org)
    client = Anthropic()

    for opp_id in args.opportunity_ids:
        print(f"\n=== {opp_id} ===")
        opp, docs = docs_for_opp(instance_url, token, opp_id)
        if opp is None:
            print("  Opportunity not found."); continue
        if not docs:
            print("  No documents on the Opp or its base."); continue

        body, doc_ids, msg = extract_one(client, args.model, system_prompt, opp, docs, instance_url, token)
        if not body:
            print("  No supported/processable documents."); continue

        # The model's JSON is the text of the first content block.
        text = "".join(b.text for b in msg.content if b.type == "text")
        print("  --- extracted JSON ---")
        print(text)

        if args.write:
            res = write_back(instance_url, token, opp_id, doc_ids, body)
            print(f"  --- written: status={res.get('status')} id={res.get('extractionId')} "
                  f"{res.get('message') or ''}")
        else:
            print("  (dry run - not written. Re-run with --write to insert the OFE.)")


if __name__ == "__main__":
    main()
