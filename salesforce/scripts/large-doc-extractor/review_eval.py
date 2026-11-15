#!/usr/bin/env python3
"""
review_eval.py - compare the extractor before and after the prompt changes, and
with the reviewer, on real deals. Read-only: nothing is written to Salesforce.

For each Opportunity Id it sends the deal's files (current deal + base deal,
labelled FILE n (CURRENT DEAL) / (PARENT CONTEXT) the way Apex labels them) to:

  1. current  - the extraction prompt before this change
                (prompts/extraction_baseline.txt, plus the org's
                OrderFormPromptAddendum with --with-org-addendum, as production runs it)
  2. updated  - force-app/.../staticresources/OrderFormPrompt.txt (this change)
  3. updated + review - the reviewer (OrderFormReviewPrompt.txt, schema-constrained
                output, the updated prompt as field definitions) run on arm 2's reply

and reports field differences, the reviewer's findings, latency, tokens and cost.
With --truth (reviewed values per deal, see truth.example.json) it also reports
missed errors per arm, errors the reviewer caught or fixed, and wrong findings.

What this does NOT do: the Apex calculations (annualisation, derived dates,
product-line alignment, deterministic checks) are not re-run off-platform, so the
reviewer here sees raw values and is told the calculated values are unavailable.
The in-org reviewer (OrderFormReviewer) also gets those. Treat these numbers as a
model-side comparison on a small sample, not as proof of quality.

Setup (once):
  python3 -m venv ~/.venvs/sf-extractor && source ~/.venvs/sf-extractor/bin/activate
  python3 -m pip install -r requirements.txt
Run:
  export ANTHROPIC_API_KEY=...            (never paste it into a file)
  python3 review_eval.py --truth truth.json 006V400000Gy4QvIAJ
  python3 review_eval.py --plan 006...    (shows what would run; no API calls)
  python3 review_eval.py --selftest       (offline checks of the schema / scoring)
"""

import argparse
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]                                   # .../salesforce
DEFAULT = ROOT / "force-app/main/default"
UPDATED_PROMPT = DEFAULT / "staticresources/OrderFormPrompt.txt"
REVIEW_PROMPT = DEFAULT / "staticresources/OrderFormReviewPrompt.txt"
BASELINE_PROMPT = HERE / "prompts/extraction_baseline.txt"
COVERAGE_CLS = DEFAULT / "classes/OrderFormReviewCoverage.cls"
REVIEWER_CLS = DEFAULT / "classes/OrderFormReviewer.cls"

EXTRACT_MODEL = "claude-sonnet-5"      # OrderFormExtractionJob.MODEL
EXTRACT_MAX_TOKENS = 8192
REVIEW_MODEL = "claude-opus-5-5"       # Order_Form_Review_Setting__mdt.Default
REVIEW_MAX_TOKENS = 16000
FALLBACK_BETA = "server-side-fallback-2026-07-01"
# USD per million tokens: input, output, cache read, cache write (5 min).
PRICES = {
    "claude-sonnet-5": (2.0, 10.0, 0.2, 2.5),
    "claude-opus-5-5": (4.0, 20.0, 0.2, 5.0),
}


# ---------------------------------------------------------------- one definition

def apex_list(path, name):
    """A List<String> constant from an Apex class - the coverage and enums are defined there once."""
    src = Path(path).read_text()
    m = re.search(r"\b" + re.escape(name) + r"\s*=\s*new List<String>\{(.*?)\};", src, re.S)
    if not m:
        raise SystemExit(f"{name} not found in {path}")
    return re.findall(r"'([^']*)'", m.group(1))


def schema_keys(prompt):
    start = prompt.index("JSON SCHEMA")
    open_ = prompt.index("\n{", start)
    close = prompt.index("\n}", open_ + 1)
    return re.findall(r'(?m)^  "([A-Za-z_]+)":', prompt[open_:close])


def allowed_fields(prompt):
    out, seen = [], set()
    for f in apex_list(COVERAGE_CLS, "PAYLOAD_FIELDS"):
        n = f[:-3] if f.endswith("__c") else f
        if n not in seen:
            seen.add(n); out.append(n)
    for k in apex_list(COVERAGE_CLS, "RAW_ONLY_KEYS") + schema_keys(prompt):
        if k not in seen:
            seen.add(k); out.append(k)
    return out


def closed(props):
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


def response_schema(prompt):
    """The same schema OrderFormReviewer.responseSchema sends."""
    s = {"type": "string"}
    slist = {"type": "array", "items": s}
    finding = closed({
        "field": {"type": "string", "enum": [""] + allowed_fields(prompt)},
        "product_ref": s, "product_component": s,
        "stage": {"type": "string", "enum": apex_list(REVIEWER_CLS, "STAGES")},
        "category": {"type": "string", "enum": apex_list(REVIEWER_CLS, "CATEGORIES")},
        "severity": {"type": "string", "enum": apex_list(REVIEWER_CLS, "SEVERITIES")},
        "explanation": s,
        "source_refs": {"type": "array", "items": closed({"file": s, "location": s})},
        "evidence": slist,
        "correction": closed({"action": {"type": "string", "enum": apex_list(REVIEWER_CLS, "ACTIONS")},
                              "value": s, "unresolved_reason": s}),
    })
    source = closed({"file": s, "role": {"type": "string", "enum": apex_list(REVIEWER_CLS, "ROLES")},
                     "readable": {"type": "boolean"},
                     "components": {"type": "array", "items": {"type": "string",
                                                               "enum": apex_list(REVIEWER_CLS, "DOC_CLASSES")}},
                     "note": s})
    return closed({
        "findings": {"type": "array", "items": finding},
        "coverage": closed({"verified": slist, "not_in_sources": slist, "not_reviewed": slist}),
        "sources_reviewed": {"type": "array", "items": source},
        "gaps": slist,
        "summary": s,
    })


def required_fields(extracted):
    """OrderFormReviewCoverage.requiredFields, from the raw extraction."""
    docs = extracted.get("Documents") or []
    has_of = any((d.get("group") or "").lower().startswith("current")
                 and ("Order Form" == d.get("class") or "Order Form" in (d.get("components") or []))
                 for d in docs if isinstance(d, dict))
    if extracted.get("Source_Document_Type") == "Email Confirmation":
        return apex_list(COVERAGE_CLS, "EMAIL_ONLY")
    out = []
    if has_of:
        out += apex_list(COVERAGE_CLS, "ECONOMICS")
        if extracted.get("Type") in ("Upsell", "Downsell", "Contract Restructure"):
            out += apex_list(COVERAGE_CLS, "AMENDMENT")
        if extracted.get("Type") == "Pilot":
            out += apex_list(COVERAGE_CLS, "PILOT")
    out += [f for f in apex_list(COVERAGE_CLS, "LEGAL") if f not in out]
    return out


# ---------------------------------------------------------------- documents

def collect_files(target_org, opp_id):
    """(opp, [(label, block)]) - current deal first, then the base deal, most relevant first."""
    import extract_large_docs as eld
    opp = eld.sf_query(target_org, "SELECT Id, Name, Type, CloseDate, Base_Opportunity__c, "
                                   f"Base_Opportunity__r.Name FROM Opportunity WHERE Id = '{opp_id}'")
    if not opp:
        return None, []
    opp = opp[0]
    groups = [(opp_id, True)]
    if opp.get("Base_Opportunity__c"):
        groups.append((opp["Base_Opportunity__c"], False))
    seen, ordered = set(), []
    for entity, is_current in groups:
        links = eld.sf_query(target_org,
                             "SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, "
                             "ContentDocument.ContentSize, ContentDocument.LatestPublishedVersionId "
                             f"FROM ContentDocumentLink WHERE LinkedEntityId = '{entity}'")
        docs = []
        for lk in links:
            if lk["ContentDocumentId"] in seen:
                continue
            seen.add(lk["ContentDocumentId"])
            cd = lk["ContentDocument"]
            docs.append((eld.relevance(cd["Title"]), cd["Title"], (cd.get("FileExtension") or "").lower(),
                         cd.get("ContentSize") or 0, cd["LatestPublishedVersionId"], is_current))
        ordered += sorted(docs)
    blocks, used, n = [], 0, 0
    for _, title, ext, size, version, is_current in ordered:
        media = eld.MEDIA.get(ext)
        if not media:
            print(f"    skip (unsupported .{ext}): {title}")
            continue
        if used + (size + 2) // 3 * 4 > eld.REQUEST_BUDGET_BYTES:
            print(f"    skip (request budget): {title}")
            continue
        raw = eld.download(target_org, version)
        if media[0] == "text":
            text = eld.docx_text(raw)
            if not text:
                continue
            block = {"type": "document", "source": {"type": "text", "media_type": media[1], "data": text}}
            used += len(text.encode())
            note = eld.WORD_NOTE
        else:
            data = base64.standard_b64encode(raw).decode("ascii")
            block = {"type": media[0], "source": {"type": "base64", "media_type": media[1], "data": data}}
            used += len(data)
            note = ""
        n += 1
        label = f"FILE {n} ({'CURRENT DEAL' if is_current else 'PARENT CONTEXT'}): {title}"
        blocks.append((label + note, block, is_current))
        print(f"    {label} ({size} bytes)")
    return opp, blocks


def deal_context(opp, blocks):
    cur = [l.split(": ", 1)[1] for l, _, c in blocks if c]
    base = sum(1 for _, _, c in blocks if not c)
    s = ("DEAL CONTEXT:\nYou are extracting the CURRENT deal below. Documents are split into two groups.\n"
         f"- Opportunity Name: {opp.get('Name') or 'unknown'}\n- Opportunity Type: {opp.get('Type') or 'unspecified'}\n"
         f"- Close Date: {opp.get('CloseDate') or 'unknown'}\n- Current-deal documents attached: {len(cur)}\n"
         "- Current-deal file name(s) (WEAK last-resort hint only - filenames are often wrong/stale and can name the "
         f"wrong entity; never prefer over the document body): {', '.join(cur) or 'n/a'}\n"
         f"- Parent-contract context documents attached: {base}")
    return s + ("\n\nExtract THE CURRENT deal. Parent-contract documents are context only: never report their figures "
                "as the current deal's.")


def user_content(opp, blocks, extra_text=None, final="Extract the CURRENT deal per the schema, using parent docs "
                                                       "only for context. Return JSON only."):
    content = [{"type": "text", "text": deal_context(opp, blocks)}]
    cur = [(l, b) for l, b, c in blocks if c]
    par = [(l, b) for l, b, c in blocks if not c]
    if cur:
        content.append({"type": "text", "text": "--- CURRENT DEAL DOCUMENTS (extract THIS deal) ---"})
        for l, b in cur:
            content += [{"type": "text", "text": l}, b]
    if par:
        content.append({"type": "text", "text": "--- PARENT CONTRACT DOCUMENTS (CONTEXT ONLY - do NOT extract these "
                                                "as the deal) ---"})
        for l, b in par:
            content += [{"type": "text", "text": l}, b]
    for t in extra_text or []:
        content.append({"type": "text", "text": t})
    content.append({"type": "text", "text": final})
    return content


# ---------------------------------------------------------------- model calls

def call(client, model, **kw):
    t0 = time.time()
    raw = client.messages.with_raw_response.create(model=model, timeout=600, **kw)
    elapsed = time.time() - t0
    body = json.loads(raw.http_response.text)
    usage = body.get("usage") or {}
    p = PRICES.get(model, (0, 0, 0, 0))
    cost = (usage.get("input_tokens", 0) * p[0] + usage.get("output_tokens", 0) * p[1]
            + (usage.get("cache_read_input_tokens") or 0) * p[2]
            + (usage.get("cache_creation_input_tokens") or 0) * p[3]) / 1e6
    text = []
    for b in body.get("content") or []:
        if b.get("type") == "fallback":
            text = []
        elif b.get("type") == "text":
            text.append(b.get("text") or "")
    return {"latency_s": round(elapsed, 1), "usage": usage, "cost_usd": round(cost, 4), "model": body.get("model"),
            "stop_reason": body.get("stop_reason"), "text": "".join(text)}


def json_from(text):
    t = text.strip()
    if not t.startswith("{"):
        f = t.find("```")
        if f >= 0:
            nl = t.find("\n", f)
            e = t.find("```", nl)
            if nl >= 0 and e > nl:
                t = t[nl + 1:e].strip()
    i, j = t.find("{"), t.rfind("}")
    return json.loads(t[i:j + 1] if i >= 0 and j > i else t)


def extract(client, system_prompt, opp, blocks):
    r = call(client, EXTRACT_MODEL, max_tokens=EXTRACT_MAX_TOKENS, system=system_prompt,
             thinking={"type": "disabled"}, messages=[{"role": "user", "content": user_content(opp, blocks)}])
    try:
        r["json"] = json_from(r["text"])
    except Exception as e:  # noqa: BLE001 - recorded, not raised
        r["json"], r["error"] = None, f"unparseable reply: {e}"
    return r


def review(client, opp, blocks, extracted, effort, fallbacks):
    defs = UPDATED_PROMPT.read_text()
    lines = extracted.get("Line_Items") or []
    refs = [f"L{i + 1}:{l.get('product')}" for i, l in enumerate(lines) if isinstance(l, dict)]
    required = required_fields(extracted)
    extra = [
        "EXTRACTION UNDER REVIEW: an off-platform run (scripts/large-doc-extractor/review_eval.py).",
        "RAW EXTRACTION (the extractor's reply - claims to verify):\n" + json.dumps(extracted, indent=1),
        "PRODUCT LINES (as returned; stable reference L<n>:<product>):\n"
        + json.dumps([dict(l, ref=r) for l, r in zip(lines, refs)], indent=1),
        "CALCULATED VALUES AND PROVENANCE: not available off-platform - the application's calculations (annual "
        "figures, derived dates, amendment arithmetic, line alignment) were not run. Judge the raw values.",
        "PROPOSED SALESFORCE PAYLOAD: not available off-platform; the raw extraction above stands in for it.",
        "DETERMINISTIC CHECKS: not run off-platform.",
        "REQUIRED COVERAGE:\nFields: " + ", ".join(required) + "\nProduct lines: " + (", ".join(refs) or "(none)"),
    ]
    output_config = {"format": {"type": "json_schema", "schema": response_schema(defs)}}
    if effort:
        output_config["effort"] = effort
    kw = dict(max_tokens=REVIEW_MAX_TOKENS,
              system=[{"type": "text", "text": REVIEW_PROMPT.read_text()},
                      {"type": "text", "text": "FIELD DEFINITIONS - the extractor's instructions, quoted for "
                                               "reference:\n\n" + defs, "cache_control": {"type": "ephemeral"}}],
              messages=[{"role": "user", "content": user_content(
                  opp, blocks, extra, "Review the extraction above against the files. Return the findings, coverage, "
                                      "sources reviewed, gaps and summary.")}],
              extra_body={"output_config": output_config})
    if fallbacks:
        kw["extra_body"]["fallbacks"] = "default"
        kw["extra_headers"] = {"anthropic-beta": FALLBACK_BETA}
    r = call(client, REVIEW_MODEL, **kw)
    r["status"], r["json"] = "Failed", None
    if r["stop_reason"] in ("refusal", "max_tokens"):
        r["error"] = f"stop_reason {r['stop_reason']}"
        return r
    try:
        r["json"] = json.loads(r["text"])
    except Exception as e:  # noqa: BLE001
        r["error"] = f"malformed reply: {e}"
        return r
    cov = r["json"]["coverage"]
    named = {f["field"] for f in r["json"]["findings"]} | {f["product_ref"] for f in r["json"]["findings"]}
    covered = set(cov["verified"]) | set(cov["not_in_sources"]) | named
    r["unreviewed"] = [i for i in required + refs if i not in covered or i in set(cov["not_reviewed"])]
    unreadable = [s["file"] for s in r["json"]["sources_reviewed"] if not s["readable"]]
    r["status"] = ("Incomplete" if r["unreviewed"] or unreadable
                   else "Findings" if r["json"]["findings"] else "Clear")
    return r


# ---------------------------------------------------------------- scoring

def norm(v):
    if v is None or (isinstance(v, str) and not v.strip()):
        return None
    if isinstance(v, bool):
        return v
    try:
        return round(float(str(v).replace(",", "")), 6)
    except ValueError:
        return str(v).strip()


def score(truth_fields, extracted):
    """[(field, expected, got, ok)] for every field with a reviewed value."""
    out = []
    for f, exp in truth_fields.items():
        got = (extracted or {}).get(f)
        out.append((f, exp, got, norm(exp) == norm(got)))
    return out


def judge_review(truth_fields, updated, findings):
    """caught / fixed / missed errors and wrong findings, against the reviewed values."""
    by_field = {}
    for f in findings:
        if f.get("field"):
            by_field.setdefault(f["field"], []).append(f)
    rows = score(truth_fields, updated)
    caught, fixed, missed, wrong = [], [], [], []
    for field, exp, got, ok in rows:
        fs = by_field.get(field, [])
        if not ok:
            if fs:
                caught.append(field)
                for f in fs:
                    c = f["correction"]
                    if (c["action"] == "set_value" and norm(c["value"]) == norm(exp)) or \
                            (c["action"] == "clear_value" and norm(exp) is None):
                        fixed.append(field)
                        break
            else:
                missed.append(field)
        else:
            for f in fs:
                if f["correction"]["action"] in ("set_value", "clear_value"):
                    wrong.append(field)
                    break
    return {"caught": caught, "fixed": sorted(set(fixed)), "missed": missed, "wrong_findings": wrong}


def regression_checks(extracted):
    """The Peel Hunt regressions, checked on any reply (no truth needed)."""
    e = extracted or {}
    ev = e.get("Extract_Evidence") if isinstance(e.get("Extract_Evidence"), dict) else {}
    issues = e.get("Issues") or []
    out = {}
    q = (ev.get("Renewal_Terms") or {}).get("quote") or ""
    out["renewal"] = {"value": e.get("Renewal_Terms"), "quote": q[:200],
                      "enum_gap_issue": any(isinstance(i, dict) and i.get("field") == "Renewal_Terms" for i in issues)}
    email = e.get("Billing_Contact_Email")
    eq = (ev.get("Billing_Contact_Email") or {}).get("quote")
    out["email"] = {"value": email, "quote": eq, "verbatim_in_quote": bool(email and eq and email.lower() in eq.lower())}
    out["tcv"] = {"value": e.get("Total_Contract_Value"),
                  "quoted": bool((ev.get("Total_Contract_Value") or {}).get("quote"))}
    soc = e.get("Subprocessor_Objection_Consequence") or ""
    out["objection_consequence_length"] = len(soc)
    out["escalator"] = {"percent": e.get("Renewal_Fee_Escalator_Percent"), "terms": e.get("Renewal_Fee_Escalator_Terms")}
    return out


# ---------------------------------------------------------------- report

def report(results, out_dir):
    lines = ["# Extractor / reviewer comparison", "",
             "Model-side comparison on real files; the Apex calculations and deterministic checks were not re-run "
             "off-platform. A small sample - read the per-deal detail, not just the totals.", ""]
    totals = {"current": [0, 0, 0.0, 0.0], "updated": [0, 0, 0.0, 0.0], "review": [0, 0, 0.0, 0.0]}
    for r in results:
        lines += [f"## {r['opp'].get('Name')} ({r['opp']['Id']})", ""]
        for arm in ("current", "updated", "review"):
            a = r.get(arm)
            if not a:
                continue
            totals[arm][2] += a["latency_s"]
            totals[arm][3] += a["cost_usd"]
            lines.append(f"- **{arm}**: {a['latency_s']} s, ${a['cost_usd']}, {a['usage'].get('input_tokens')} in / "
                         f"{a['usage'].get('output_tokens')} out, stop {a['stop_reason']}"
                         + (f", status {a.get('status')}" if arm == "review" else "")
                         + (f" - {a['error']}" if a.get("error") else ""))
        cur, upd = (r.get("current") or {}).get("json") or {}, (r.get("updated") or {}).get("json") or {}
        diff = [k for k in sorted(set(cur) | set(upd)) if k not in ("Extract_Evidence",) and norm(json.dumps(cur.get(k), sort_keys=True)) != norm(json.dumps(upd.get(k), sort_keys=True))]
        lines += ["", f"Fields that changed between current and updated ({len(diff)}):", ""]
        for k in diff:
            lines.append(f"- `{k}`: {json.dumps(cur.get(k))[:160]} -> {json.dumps(upd.get(k))[:160]}")
        if r.get("truth"):
            lines += ["", "| field | reviewed | current | updated |", "|---|---|---|---|"]
            sc, su = dict((f, ok) for f, _, _, ok in score(r["truth"], cur)), dict((f, ok) for f, _, _, ok in score(r["truth"], upd))
            for f, exp in r["truth"].items():
                lines.append(f"| {f} | {json.dumps(exp)} | {'ok' if sc[f] else 'WRONG: ' + json.dumps(cur.get(f))[:60]} | "
                             f"{'ok' if su[f] else 'WRONG: ' + json.dumps(upd.get(f))[:60]} |")
                totals["current"][0] += 0 if sc[f] else 1
                totals["updated"][0] += 0 if su[f] else 1
                totals["current"][1] += 1
                totals["updated"][1] += 1
            if r.get("judged"):
                j = r["judged"]
                lines += ["", f"Reviewer vs reviewed values: caught {j['caught']}, fixed {j['fixed']}, "
                              f"missed {j['missed']}, wrong findings {j['wrong_findings']}"]
                totals["review"][0] += len(j["missed"])
                totals["review"][1] += len(j["wrong_findings"])
        rev = (r.get("review") or {}).get("json")
        if rev:
            lines += ["", f"Reviewer findings ({len(rev['findings'])}):", ""]
            for f in rev["findings"]:
                c = f["correction"]
                lines.append(f"- [{f['severity']}] {f['field'] or f['product_ref']} ({f['stage']}/{f['category']}): "
                             f"{f['explanation']} -> {c['action']}"
                             + (f" `{c['value']}`" if c['value'] else "") + (f" ({c['unresolved_reason']})" if c['unresolved_reason'] else ""))
            if (r.get("review") or {}).get("unreviewed"):
                lines.append(f"- not reviewed: {', '.join(r['review']['unreviewed'])}")
            if rev.get("gaps"):
                lines.append(f"- gaps: {'; '.join(rev['gaps'])}")
        lines += ["", "Regression checks (updated): `" + json.dumps(r.get("regressions_updated"))[:600] + "`",
                  "", "Regression checks (current): `" + json.dumps(r.get("regressions_current"))[:600] + "`", ""]
    lines += ["## Totals", "", "| arm | errors vs reviewed values | fields checked | latency (s) | cost (USD) |",
              "|---|---|---|---|---|"]
    lines.append(f"| current | {totals['current'][0]} | {totals['current'][1]} | {totals['current'][2]:.1f} | {totals['current'][3]:.4f} |")
    lines.append(f"| updated | {totals['updated'][0]} | {totals['updated'][1]} | {totals['updated'][2]:.1f} | {totals['updated'][3]:.4f} |")
    lines.append(f"| updated + review | {totals['review'][0]} missed by the reviewer, {totals['review'][1]} wrong findings | "
                 f"{totals['updated'][1]} | {totals['updated'][2] + totals['review'][2]:.1f} | {totals['updated'][3] + totals['review'][3]:.4f} |")
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "report.md").write_text("\n".join(lines) + "\n")
    (out_dir / "results.json").write_text(json.dumps(results, indent=1, default=str))
    print(f"\nWrote {out_dir / 'report.md'} and results.json")


# ---------------------------------------------------------------- main

def selftest():
    defs = UPDATED_PROMPT.read_text()
    sch = response_schema(defs)

    def walk(n):
        if isinstance(n, dict):
            if n.get("type") == "object":
                assert n["additionalProperties"] is False and set(n["required"]) == set(n["properties"]), n
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(sch)
    keys = schema_keys(defs)
    assert "Issues" in keys and "Pricing_Structure" not in keys and "Renewal_Fee_Escalator_Terms" in keys
    assert "Ramp_Schedule" not in schema_keys(BASELINE_PROMPT.read_text())
    assert "Renewal_Terms" in required_fields({"Documents": [{"group": "Current", "class": "MSA", "components": ["Order Form"]}]})
    assert "Named_Users" in required_fields({"Source_Document_Type": "Email Confirmation"})
    truth = {"Renewal_Terms": None, "Billing_Contact_Email": "accounts-payable@example.com", "Seat_Licenses": 25}
    upd = {"Renewal_Terms": "Auto-renew (30-day)", "Billing_Contact_Email": "accountspayable@example.com", "Seat_Licenses": 25}
    j = judge_review(truth, upd, [
        {"field": "Renewal_Terms", "correction": {"action": "clear_value", "value": "", "unresolved_reason": ""}},
        {"field": "Seat_Licenses", "correction": {"action": "set_value", "value": "30", "unresolved_reason": ""}}])
    assert j == {"caught": ["Renewal_Terms"], "fixed": ["Renewal_Terms"], "missed": ["Billing_Contact_Email"],
                 "wrong_findings": ["Seat_Licenses"]}, j
    rc = regression_checks({"Billing_Contact_Email": "accountspayable@example.com",
                            "Extract_Evidence": {"Billing_Contact_Email": {"quote": "AP: accounts-payable@example.com"}}})
    assert rc["email"]["verbatim_in_quote"] is False
    print(f"selftest ok: {len(keys)} schema keys, {len(allowed_fields(defs))} reviewable fields, "
          f"{len(json.dumps(sch))}-char response schema")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("opportunity_ids", nargs="*")
    ap.add_argument("--target-org", default="rogo")
    ap.add_argument("--truth", help="JSON of reviewed values per opportunity (see truth.example.json)")
    ap.add_argument("--with-org-addendum", action="store_true",
                    help="append the org's OrderFormPromptAddendum to the current prompt, as production runs it")
    ap.add_argument("--effort", default="low", help="reviewer output_config.effort (default low, as configured)")
    ap.add_argument("--no-fallbacks", action="store_true", help="do not send fallbacks: default")
    ap.add_argument("--skip-current", action="store_true", help="run only the updated extractor and the reviewer")
    ap.add_argument("--out", default=str(HERE / "eval-output"))
    ap.add_argument("--plan", action="store_true", help="show what would run; no API calls")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return
    if not args.opportunity_ids:
        sys.exit("Pass one or more Opportunity Ids (or --selftest).")
    truth = json.loads(Path(args.truth).read_text()) if args.truth else {}
    calls = len(args.opportunity_ids) * (2 if args.skip_current else 3)
    print(f"{len(args.opportunity_ids)} deal(s), {calls} API calls: extraction on {EXTRACT_MODEL} "
          f"({'updated' if args.skip_current else 'current + updated'}), review on {REVIEW_MODEL} (effort {args.effort}).")
    if args.plan:
        return
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Set ANTHROPIC_API_KEY first.")
    from anthropic import Anthropic
    import extract_large_docs as eld
    client = Anthropic()
    current_prompt = BASELINE_PROMPT.read_text()
    if args.with_org_addendum:
        rows = eld.sf_query(args.target_org, "SELECT Id FROM StaticResource WHERE Name = 'OrderFormPromptAddendum'")
        if rows:
            current_prompt += "\n\n" + eld.sf_rest(args.target_org, f"/services/data/{eld.API_VERSION}/sobjects/"
                                                                    f"StaticResource/{rows[0]['Id']}/Body")
    updated_prompt = UPDATED_PROMPT.read_text()
    results = []
    for opp_id in args.opportunity_ids:
        print(f"\n=== {opp_id} ===")
        opp, blocks = collect_files(args.target_org, opp_id)
        if not opp or not blocks:
            print("  no opportunity or no usable files")
            continue
        r = {"opp": {"Id": opp["Id"], "Name": opp.get("Name")}, "truth": (truth.get(opp_id) or {}).get("fields")}
        if not args.skip_current:
            r["current"] = extract(client, current_prompt, opp, blocks)
            print(f"  current: {r['current']['latency_s']} s, ${r['current']['cost_usd']}")
        r["updated"] = extract(client, updated_prompt, opp, blocks)
        print(f"  updated: {r['updated']['latency_s']} s, ${r['updated']['cost_usd']}")
        if r["updated"].get("json"):
            r["review"] = review(client, opp, blocks, r["updated"]["json"], args.effort, not args.no_fallbacks)
            print(f"  review: {r['review']['latency_s']} s, ${r['review']['cost_usd']}, {r['review']['status']}")
            if r["truth"] and r["review"].get("json"):
                r["judged"] = judge_review(r["truth"], r["updated"]["json"], r["review"]["json"]["findings"])
        r["regressions_updated"] = regression_checks((r.get("updated") or {}).get("json"))
        r["regressions_current"] = regression_checks((r.get("current") or {}).get("json"))
        for arm in ("current", "updated", "review"):
            if r.get(arm):
                r[arm].pop("text", None)
        results.append(r)
    report(results, Path(args.out))


if __name__ == "__main__":
    sys.path.insert(0, str(HERE))
    main()
