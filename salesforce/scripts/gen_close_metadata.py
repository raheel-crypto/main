"""Generate the HXL metadata for the Close Opportunity agent tools.

Single source of truth for the response field lists so the widget schemas,
Lightning Types, renderers, and Agent Action schemas cannot drift from each other.
"""
import json, os, re

PKG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "force-app", "main", "default")
ROW_TYPE = "@apexClassType/c__OpportunityCloseService$Row"
ROW_ITEM_PROPS = {
    "label": {"title": "Label", "lightning:type": "lightning__textType"},
    "value": {"title": "Value", "lightning:type": "lightning__multilineTextType"},
    "icon": {"title": "Icon", "lightning:type": "lightning__textType"},
    "color": {"title": "Color", "lightning:type": "lightning__textType"},
}
CHOICE_TYPE = "@apexClassType/c__OpportunityCloseService$Choice"
CHOICE_ITEM_PROPS = {
    "label": {"title": "Label", "lightning:type": "lightning__textType"},
    "prompt": {"title": "Prompt", "lightning:type": "lightning__multilineTextType"},
    "variant": {"title": "Variant", "lightning:type": "lightning__textType"},
}
LIST_KINDS = {"rows": (ROW_TYPE, ROW_ITEM_PROPS), "choices": (CHOICE_TYPE, CHOICE_ITEM_PROPS)}

# kind: text | long | bool | int | rows | choices
READINESS = [
    ("opportunityId", "text", "Opportunity Id"), ("opportunityName", "text", "Opportunity Name"),
    ("accountName", "text", "Account Name"), ("stageName", "text", "Stage"), ("amount", "text", "Amount"),
    ("closeDate", "text", "Close Date"), ("opportunityType", "text", "Opportunity Type"), ("ownerName", "text", "Owner"),
    ("statusLabel", "text", "Status Label"), ("statusVariant", "text", "Status Variant"),
    ("statusMessage", "long", "Status Message"), ("isClosed", "bool", "Is Closed"), ("canClose", "bool", "Can Close"),
    ("isRestructure", "bool", "Is Contract Restructure"), ("hasSignedDocument", "bool", "Has Signed Document"),
    ("missingSignedDocument", "bool", "Missing Signed Document"), ("signedDocumentText", "long", "Signed Document Text"),
    ("hasMissingFields", "bool", "Has Missing Fields"), ("missingFieldCount", "int", "Missing Field Count"),
    ("missingFieldsText", "long", "Missing Fields Text"), ("checklist", "rows", "Checklist"),
    ("neededRows", "rows", "Needed Rows"), ("completeRows", "rows", "Complete Rows"),
    ("completedCount", "int", "Completed Count"), ("totalFieldCount", "int", "Total Field Count"),
    ("neededTitle", "text", "Needed Title"), ("completeTitle", "text", "Complete Title"),
    ("progressLabel", "text", "Progress Label"), ("filesUrl", "text", "Files URL"), ("uploadUrl", "text", "Upload URL"),
    ("closeWonPrompt", "long", "Close Won Prompt"), ("closeLostPrompt", "long", "Close Lost Prompt"),
    ("opportunityUrl", "text", "Opportunity URL"),
]
SUBMISSION = [
    ("opportunityId", "text", "Opportunity Id"), ("opportunityName", "text", "Opportunity Name"),
    ("accountName", "text", "Account Name"), ("status", "text", "Status"), ("statusLabel", "text", "Status Label"),
    ("statusVariant", "text", "Status Variant"), ("headline", "text", "Headline"), ("message", "long", "Message"),
    ("isPreview", "bool", "Is Preview"), ("isSubmitted", "bool", "Is Submitted"), ("isBlocked", "bool", "Is Blocked"),
    ("hasProblems", "bool", "Has Problems"), ("problems", "rows", "Problems"), ("rows", "rows", "Rows"),
    ("hasRecommendation", "bool", "Has AI Recommendation"), ("aiSummary", "long", "AI Summary"),
    ("recommendedReason", "text", "Recommended Reason"), ("recommendedCompetitor", "text", "Recommended Competitor"),
    ("recommendedNarrative", "long", "Recommended Narrative"), ("aiConfidence", "text", "AI Confidence"),
    ("aiFailed", "bool", "AI Failed"), ("aiFailureReason", "long", "AI Failure Reason"),
    ("reasonChoices", "choices", "Loss Reason Choices"), ("hasReasonChoices", "bool", "Has Loss Reason Choices"),
    ("lobChoices", "choices", "LOB/Division Choices"), ("hasLobChoices", "bool", "Has LOB/Division Choices"),
    ("needsSignedDocument", "bool", "Needs Signed Document"), ("filesUrl", "text", "Files URL"),
    ("uploadUrl", "text", "Upload URL"),
    ("aiRunning", "bool", "AI Running"), ("aiStatusText", "long", "AI Status Text"),
    ("confirmPrompt", "long", "Confirm Prompt"), ("changePrompt", "long", "Change Prompt"),
    ("refreshPrompt", "long", "Refresh Prompt"), ("retryPrompt", "long", "Retry Prompt"),
    ("opportunityUrl", "text", "Opportunity URL"),
]

CLT_TYPES = {"text": "lightning__textType", "long": "lightning__multilineTextType", "bool": "lightning__booleanType",
             "int": "lightning__integerType", "rows": ROW_TYPE, "choices": CHOICE_TYPE}
WIDGET_TYPES = {"text": "lightning__textType", "long": "lightning__multilineTextType", "bool": "lightning__booleanType",
                "int": "lightning__numberType"}
ACTION_TYPES = {"text": "lightning__textType", "long": "lightning__textType", "bool": "lightning__booleanType",
                "int": "lightning__integerType"}


def w(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content if isinstance(content, str) else json.dumps(content, indent=2) + "\n")


def widget_schema(title, desc, fields):
    props = {}
    for key, kind, label in fields:
        if kind in LIST_KINDS:
            props[key] = {"title": label, "lightning:type": "lightning__listType",
                          "items": {"lightning:type": "lightning__objectType", "properties": LIST_KINDS[kind][1]}}
        else:
            props[key] = {"title": label, "lightning:type": WIDGET_TYPES[kind]}
    return {"title": title, "description": desc, "type": "object",
            "properties": {"attributes": {"lightning:type": "lightning__objectType", "properties": props}}}


def response_clt(title, desc, fields):
    return {"title": title, "description": desc, "type": "object", "lightning:type": "lightning__objectType",
            "lightning:tags": ["mcp"], "unevaluatedProperties": False,
            "properties": {k: {"title": lbl, "lightning:type": CLT_TYPES[kind]} for k, kind, lbl in fields}}


def envelope_clt(title, desc, response_name):
    return {"title": title, "description": desc, "type": "object", "lightning:type": "lightning__objectType",
            "lightning:tags": ["mcp"], "unevaluatedProperties": False,
            "properties": {"actionName": {"title": "actionName", "lightning:type": "lightning__textType"},
                           "isSuccess": {"title": "isSuccess", "lightning:type": "lightning__booleanType"},
                           "outputValues": {"title": "outputValues", "lightning:type": "c__" + response_name}}}


def renderer(widget, fields):
    return {"renderer": {"componentOverrides": {"$": {"definition": "@widget/c/" + widget,
            "attributes": {k: "{!$attrs.outputValues." + k + "}" for k, _, _ in fields}}}}}


def action_output(fields):
    props = {}
    for key, kind, label in fields:
        p = {"title": label, "description": label, "lightning:isPII": False,
             "copilotAction:isDisplayable": True, "copilotAction:isUsedByPlanner": True,
             "copilotAction:useHydratedPrompt": False}
        if kind in LIST_KINDS:
            p.update({"maxItems": 2000, "items": {"lightning:type": LIST_KINDS[kind][0]}, "lightning:type": "lightning__listType"})
        else:
            p["lightning:type"] = ACTION_TYPES[kind]
        props[key] = p
    return {"unevaluatedProperties": False, "properties": props, "lightning:type": "lightning__objectType"}


def action_input(inputs, required):
    props = {}
    for key, ltype, label, desc in inputs:
        props[key] = {"title": label, "description": desc, "lightning:type": ltype, "lightning:isPII": False,
                      "copilotAction:isUserInput": False}
    return {"required": required, "unevaluatedProperties": False, "properties": props,
            "lightning:type": "lightning__objectType"}


def action_meta(desc, target, label, progress):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<GenAiFunction xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>{desc}</description>
    <invocationTarget>{target}</invocationTarget>
    <invocationTargetType>apex</invocationTargetType>
    <isConfirmationRequired>false</isConfirmationRequired>
    <isIncludeInProgressIndicator>true</isIncludeInProgressIndicator>
    <masterLabel>{label}</masterLabel>
    <progressIndicatorMessage>{progress}</progressIndicatorMessage>
</GenAiFunction>
"""


def widget_meta(label, desc):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<UiWidgetBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <masterLabel>{label}</masterLabel>
    <description>{desc}</description>
    <widgetType>JSON</widgetType>
</UiWidgetBundle>
"""


# ─── UEM helpers ─────────────────────────────────────────────────────────

def text(t, **attrs):
    a = {"text": t}
    a.update(attrs)
    return {"definition": "tile/text", "attributes": a}

def col(children, **attrs):
    a = {"gap": "md"}
    a.update(attrs)
    return {"definition": "tile/column", "attributes": a, "children": children}

def row(children, **attrs):
    a = {"gap": "md", "align": "center"}
    a.update(attrs)
    return {"definition": "tile/row", "attributes": a, "children": children}

def sep():
    return {"definition": "tile/separator", "attributes": {"orientation": "horizontal"}}

def badge(label, variant):
    return {"definition": "tile/badge", "attributes": {"label": label, "variant": variant}}

def icon(name, color="muted", size="sm"):
    return {"definition": "tile/icon", "attributes": {"name": name, "size": size, "color": color, "alt": ""}}

def callout(title, desc, variant, cond=None, body=None):
    attrs = {"title": title, "variant": variant}
    if desc:
        attrs["description"] = desc
    node = {"definition": "tile/callout", "attributes": attrs}
    if body:
        node["children"] = [text(body, variant="body")]
    if cond:
        node["meta"] = {"if": cond}
    return node

def button(label, variant, action):
    return {"definition": "tile/button", "attributes": {"label": label, "variant": variant, "actions": {"click": [action]}}}

def send(content):
    return {"definition": "action/sendMessage", "attributes": {"content": content}}

def open_link(url):
    return {"definition": "action/openLink", "attributes": {"url": url, "target": "_blank"}}

def with_if(node, cond):
    node.setdefault("meta", {})["if"] = cond
    return node

def stat(label, value):
    return col([text(label, variant="caption", color="muted"), text(value, variant="h4")], gap="xs", width="stretch")

def kv(label, value_binding):
    return row([icon("user", "muted"), text(label, variant="body", weight="semibold"), text(value_binding, variant="body")], gap="sm")


def header(name_b, sub_b, badge_label_b, badge_variant_b):
    return row([
        col([text(name_b, variant="h2"), text(sub_b, variant="caption", color="muted")], gap="xs", width="stretch"),
        badge(badge_label_b, badge_variant_b),
    ], justify="between", align="start")


def envelope(children):
    return {"type": "lightning__agentforceWidget",
            "contentBody": {"widgetBody": {"definition": "tile/widget", "children": [col(children)]}}}


def table(list_binding, caption, first_header, second_header):
    """Renders a Row list as a native table (two columns), far smaller than one block tree per row."""
    return {"definition": "tile/table", "attributes": {
        "caption": caption, "size": "sm", "appearance": "default",
        "columns": [{"key": "label", "header": first_header}, {"key": "value", "header": second_header}],
        "rows": list_binding,
    }}

def progress(label_b, value_b, max_b, color="primary"):
    return {"definition": "tile/progress", "attributes": {
        "label": label_b, "value": value_b, "max": max_b, "shape": "linear", "size": "sm", "color": color}}

def accordion(items):
    return {"definition": "tile/accordion", "attributes": {}, "children": items}

def accordion_item(title_b, children, icon_name=None, expanded=False, cond=None):
    attrs = {"title": title_b, "isExpanded": expanded}
    if icon_name:
        attrs["iconName"] = icon_name
        attrs["iconAlt"] = ""
    node = {"definition": "tile/accordionitem", "attributes": attrs, "children": children}
    if cond:
        node["meta"] = {"if": cond}
    return node

def markdown(source_b):
    return {"definition": "tile/markdown", "attributes": {"source": source_b}}

def choice_buttons(list_binding, item="$choice"):
    """One button per Choice: label and variant come from the item, the click sends the item's prompt."""
    node = button("{!" + item + ".label}", "{!" + item + ".variant}", send("{!" + item + ".prompt}"))
    node["meta"] = {"forEach": list_binding, "forItem": item}
    return node


# ─── Widget 1: closeReadinessCard ────────────────────────────────────────

readiness_body = envelope([
    col([
        header("{!$attrs.opportunityName}", "{!$attrs.accountName}", "{!$attrs.statusLabel}", "{!$attrs.statusVariant}"),
        row([stat("Stage", "{!$attrs.stageName}"), stat("Amount", "{!$attrs.amount}"),
             stat("Close Date", "{!$attrs.closeDate}"), stat("Type", "{!$attrs.opportunityType}")], gap="lg", align="start"),
        text("{!$attrs.statusMessage}", variant="body"),
    ], gap="md"),
    col([
        callout("Signed order form required", "{!$attrs.signedDocumentText}", "error", "{!$attrs.missingSignedDocument}"),
        with_if(row([
            button("Upload signed order form", "primary", open_link("{!$attrs.uploadUrl}")),
            button("Open Files in Salesforce", "secondary", open_link("{!$attrs.filesUrl}")),
        ], gap="sm"), "{!$attrs.missingSignedDocument}"),
        with_if(text("Drop the signed file on the upload page; it is saved to this opportunity with the __signed name. Then check again.",
                     variant="caption", color="muted"), "{!$attrs.missingSignedDocument}"),
        with_if(row([icon("check-circle", "success"), text("Signed order form", variant="body", weight="semibold"),
                     text("{!$attrs.signedDocumentText}", variant="body", color="muted")], gap="sm"), "{!$attrs.hasSignedDocument}"),
    ], gap="sm"),
    sep(),
    col([
        text("Closed Won checklist", variant="h3"),
        progress("{!$attrs.progressLabel}", "{!$attrs.completedCount}", "{!$attrs.totalFieldCount}"),
        text("{!$attrs.progressLabel}", variant="caption", color="muted"),
        accordion([
            accordion_item("{!$attrs.neededTitle}", [table("{!$attrs.neededRows}", "Fields that still need a value", "Field", "Status")],
                           icon_name="alert-circle", expanded=True, cond="{!$attrs.hasMissingFields}"),
            accordion_item("{!$attrs.completeTitle}", [table("{!$attrs.completeRows}", "Fields that already have a value", "Field", "Current value")],
                           icon_name="check-circle", expanded=False),
        ]),
    ], gap="sm"),
    col([
        with_if(row([
            button("Close as Won", "primary", send("{!$attrs.closeWonPrompt}")),
            button("Close as Lost", "secondary", send("{!$attrs.closeLostPrompt}")),
            button("Open in Salesforce", "secondary", open_link("{!$attrs.opportunityUrl}")),
        ], gap="sm"), "{!$attrs.canClose}"),
        with_if(row([button("Open in Salesforce", "secondary", open_link("{!$attrs.opportunityUrl}"))], gap="sm"), "{!$attrs.isClosed}"),
    ], gap="sm"),
])

# ─── Widget 2: closeSubmissionCard ───────────────────────────────────────

submission_body = envelope([
    col([
        header("{!$attrs.headline}", "{!$attrs.opportunityName}", "{!$attrs.statusLabel}", "{!$attrs.statusVariant}"),
        text("{!$attrs.message}", variant="body"),
    ], gap="md"),
    with_if(col([
        sep(),
        text("AI recommendation", variant="h3"),
        row([stat("Recommended reason", "{!$attrs.recommendedReason}"),
             stat("Recommended competitor", "{!$attrs.recommendedCompetitor}"),
             stat("Confidence", "{!$attrs.aiConfidence}")], gap="lg", align="start"),
        markdown("{!$attrs.recommendedNarrative}"),
        accordion([
            accordion_item("AI analysis details", [markdown("{!$attrs.aiSummary}")], icon_name="file-text", expanded=False),
        ]),
    ], gap="sm"), "{!$attrs.hasRecommendation}"),
    col([
        callout("AI analysis running", None, "info", "{!$attrs.aiRunning}", body="{!$attrs.aiStatusText}"),
        with_if(row([button("Refresh preview", "secondary", send("{!$attrs.refreshPrompt}"))], gap="sm"), "{!$attrs.aiRunning}"),
        callout("AI analysis unavailable", None, "warning", "{!$attrs.aiFailed}", body="{!$attrs.aiFailureReason}"),
        with_if(row([button("Retry AI analysis", "secondary", send("{!$attrs.retryPrompt}"))], gap="sm"), "{!$attrs.aiFailed}"),
    ], gap="sm"),
    with_if(col([
        callout("Signed order form required", "Closed Won needs the signed order form attached to the opportunity.", "error"),
        row([
            button("Upload signed order form", "primary", open_link("{!$attrs.uploadUrl}")),
            button("Open Files in Salesforce", "secondary", open_link("{!$attrs.filesUrl}")),
        ], gap="sm"),
        text("Drop the signed file on the upload page; it is saved to this opportunity with the __signed name. Then try again.",
             variant="caption", color="muted"),
    ], gap="sm"), "{!$attrs.needsSignedDocument}"),
    col([
        with_if(col([
            text("Pick the loss reason", variant="h3"),
            text("Choose a reason to preview with it, or ask for the full list.", variant="caption", color="muted"),
            row([choice_buttons("{!$attrs.reasonChoices}")], gap="sm", isWrapped=True),
        ], gap="sm"), "{!$attrs.hasReasonChoices}"),
        with_if(col([
            text("Pick the LOB/Division", variant="h3"),
            text("The suggestion comes from the account type. Pick another to preview with it.", variant="caption", color="muted"),
            row([choice_buttons("{!$attrs.lobChoices}", item="$lob")], gap="sm", isWrapped=True),
        ], gap="sm"), "{!$attrs.hasLobChoices}"),
    ], gap="md"),
    with_if(col([
        callout("Fix these before submitting", "Nothing has been saved.", "error"),
        table("{!$attrs.problems}", "Problems to fix", "Field", "Issue"),
    ], gap="sm"), "{!$attrs.hasProblems}"),
    sep(),
    col([
        text("Values", variant="h3"),
        table("{!$attrs.rows}", "Values to be written", "Field", "Value"),
    ], gap="sm"),
    col([
        callout("Nothing saved yet", "Confirm to submit these values, or tell the agent what to change.", "info", "{!$attrs.isPreview}"),
        with_if(row([
            button("Confirm and submit", "primary", send("{!$attrs.confirmPrompt}")),
            button("Change something", "secondary", send("{!$attrs.changePrompt}")),
        ], gap="sm"), "{!$attrs.isPreview}"),
        callout("Submitted", None, "success", "{!$attrs.isSubmitted}", body="{!$attrs.message}"),
        row([button("Open in Salesforce", "secondary", open_link("{!$attrs.opportunityUrl}"))], gap="sm"),
    ], gap="sm"),
])

# ─── Emit widgets ────────────────────────────────────────────────────────

w(f"{PKG}/uiWidgets/closeReadinessCard/closeReadinessCard.json", readiness_body)
w(f"{PKG}/uiWidgets/closeReadinessCard/schema.json", widget_schema(
    "Close Readiness Card", "Shows whether an opportunity can be closed: status, signed order form, a progress bar, and the Closed Won fields grouped into needed and complete.", READINESS))
w(f"{PKG}/uiWidgets/closeReadinessCard/closeReadinessCard.uiwidget-meta.xml", widget_meta(
    "Close Readiness Card", "Whether an opportunity can be closed from the agent: status badge, signed order form check, completion progress, Closed Won fields grouped into needed and complete, and buttons to start Closed Won or Closed Lost."))

w(f"{PKG}/uiWidgets/closeSubmissionCard/closeSubmissionCard.json", submission_body)
w(f"{PKG}/uiWidgets/closeSubmissionCard/schema.json", widget_schema(
    "Close Submission Card", "Preview, problems, or result of a Closed Won or Closed Lost submission, with loss reason choice buttons and confirm and change buttons.", SUBMISSION))
w(f"{PKG}/uiWidgets/closeSubmissionCard/closeSubmissionCard.uiwidget-meta.xml", widget_meta(
    "Close Submission Card", "Preview, validation problems, or result of submitting an opportunity as Closed Won or Closed Lost, with an AI recommendation section, loss reason choice buttons, and confirm buttons."))

# ─── Emit Lightning Types + renderers ───────────────────────────────────

TOOLS = [
    # (tool api name, Apex class, widget, fields, label)
    ("getCloseReadiness", "GetCloseReadiness", "closeReadinessCard", READINESS, "Get Close Readiness"),
    ("submitClosedWon", "SubmitClosedWon", "closeSubmissionCard", SUBMISSION, "Submit Closed Won"),
    ("submitClosedLost", "SubmitClosedLost", "closeSubmissionCard", SUBMISSION, "Submit Closed Lost"),
]
for tool, cls, widget, fields, label in TOOLS:
    w(f"{PKG}/lightningTypes/{tool}Response/schema.json", response_clt(
        f"{label} Response", f"Response fields from the {cls} invocable action. Rendered by the {widget} widget.", fields))
    w(f"{PKG}/lightningTypes/{tool}/schema.json", envelope_clt(
        label, f"Invocable-action result envelope for the {cls} MCP tool. outputValues carries the response rendered by the {widget} widget.", f"{tool}Response"))
    w(f"{PKG}/lightningTypes/{tool}/renderer.json", renderer(widget, fields))

# ─── Emit Agent Actions ─────────────────────────────────────────────────

opp_input = ("opportunityId", "lightning__textType", "Opportunity Id", "The 15 or 18 character Salesforce Id of the Opportunity. Starts with 006.")
confirm_input = ("confirm", "lightning__booleanType", "Confirm", "False or omitted previews without saving. True performs the close. Only set true after the user has reviewed the preview.")

w(f"{PKG}/genAiFunctions/Get_Close_Readiness/Get_Close_Readiness.genAiFunction-meta.xml", action_meta(
    "Checks whether an Opportunity is ready to be closed: whether a signed order form is attached and which Closed Won fields still need values. Read-only. Use before closing an opportunity.",
    "GetCloseReadiness", "Get Close Readiness", "Checking the opportunity..."))
w(f"{PKG}/genAiFunctions/Get_Close_Readiness/input/schema.json", action_input([opp_input], ["opportunityId"]))
w(f"{PKG}/genAiFunctions/Get_Close_Readiness/output/schema.json", action_output(READINESS))

WON_INPUTS = [opp_input, confirm_input,
    ("lobDivision", "lightning__textType", "LOB/Division", "Picklist: Investment Banking, Commercial Banking, Corporate Banking, Corporate Finance, Wealth Management, Asset Management, Private Equity, Private Credit, Hedge Fund, Venture Capital / Ventures, Corporate Development, Sales & Trading / Markets."),
    ("pricingStructure", "lightning__textType", "Pricing Structure", "Picklist: Seats: Unlimited Usage, No Throttling; Seats: Unlimited Usage, with Throttling; Seats: Credit-Based Usage; ELA: Unlimited Usage, No Throttling; ELA: Unlimited Usage, with Throttling; ELA: Credit-Based Usage; Custom."),
    ("dealDescription", "lightning__textType", "Deal Description", "What was sold."),
    ("purchaseDriver", "lightning__textType", "Purchase Driver", "Why the customer bought."),
    ("rolloutTimeline", "lightning__textType", "Rollout Timeline", "Picklist: Immediate, Delayed, Phased."),
    ("successCriteria", "lightning__textType", "Success Criteria", "How the customer will judge success."),
    ("upsellPotential", "lightning__textType", "Upsell Potential", "Picklist: Yes, No, Maybe."),
    ("implementationNotes", "lightning__textType", "Implementation Notes", "Notes for the implementation team."),
    ("keyRisks", "lightning__textType", "Key Risks", "Risks to the account."),
    ("amount", "lightning__numberType", "Amount", "Opportunity amount."),
    ("contractStartDate", "lightning__dateType", "Contract Start Date", "YYYY-MM-DD."),
    ("contractEndDate", "lightning__dateType", "Contract End Date", "YYYY-MM-DD. Must be after the start date."),
    ("contractLengthMonths", "lightning__integerType", "Contract Length (Months)", "Whole months."),
    ("annualRecurringRevenue", "lightning__numberType", "Annual Recurring Revenue", "ARR."),
    ("totalContractValue", "lightning__numberType", "Total Contract Value", "TCV."),
    ("licenseFee", "lightning__numberType", "License Fee", "Annual license fee."),
    ("platformConnectionFee", "lightning__numberType", "Platform Connection Fee", "Platform connection fee."),
    ("professionalServicesFees", "lightning__numberType", "Professional Services Fees", "Professional services fees."),
    ("seatLicenses", "lightning__integerType", "Seat Licenses", "Number of seats."),
    ("paymentTerms", "lightning__textType", "Payment Terms", "Picklist: Annual, Semi-Annual, Quarterly, Monthly."),
    ("creditTerms", "lightning__textType", "Credit Terms", "Picklist: Net-15, Net-30, Net-45, Net-60."),
    ("billingNotes", "lightning__textType", "Billing Notes", "Under 255 characters."),
    ("billingContactEmail", "lightning__textType", "Billing Contact Email", "Email address of the billing contact."),
    ("renewalTerms", "lightning__textType", "Renewal Terms", "Picklist: Auto-renew (90-day), Auto-renew (60-day), Auto-renew (30-day), Manual renewal."),
    ("isEla", "lightning__booleanType", "ELA", "True for an enterprise license agreement."),
    ("optOut", "lightning__booleanType", "Opt Out", "True when the contract has an opt-out clause."),
    ("optOutDate", "lightning__dateType", "Opt-Out Date", "YYYY-MM-DD. Required when Opt Out is true."),
    ("willingToProvideReferences", "lightning__booleanType", "Willing to Provide References", "Whether the account will act as a reference."),
]
w(f"{PKG}/genAiFunctions/Submit_Closed_Won/Submit_Closed_Won.genAiFunction-meta.xml", action_meta(
    "Submits an Opportunity as Closed Won the way the Close Opportunity screen flow does: validates the finance and handoff fields, requires a signed order form on the record, previews when confirm is false, and on confirm writes the fields, notifies RevOps in Slack, and queues order form extraction. RevOps stamps the stage. Blank inputs keep existing values.",
    "SubmitClosedWon", "Submit Closed Won", "Submitting Closed Won..."))
w(f"{PKG}/genAiFunctions/Submit_Closed_Won/input/schema.json", action_input(WON_INPUTS, ["opportunityId"]))
w(f"{PKG}/genAiFunctions/Submit_Closed_Won/output/schema.json", action_output(SUBMISSION))

LOST_INPUTS = [opp_input, confirm_input,
    ("retryAi", "lightning__booleanType", "Retry AI", "True starts the background AI loss analysis again, for example after it failed. Ignored when confirm is true."),
    ("primaryReason", "lightning__textType", "CL Primary Reason", "Required picklist: Bad Fit Disqualified, Budget Financial, Business Change, Competitive Loss, Duplicate, No Need, No Show / Buyer Canceled, Product / Technical Gap, Security Compliance, Timing Priority, Wrong Authority."),
    ("secondaryReason", "lightning__textType", "CL Secondary Reason", "Optional picklist: Hebbia, Claude, Perplexity, BlueFlame, Internal Build, Inaccuracy / Hallucination, Latency / Performance, Missing 3P Data, Missing 1P Data, Budget Not Approved, Funding Shifted, Perceived price too high."),
    ("finalCompetitor", "lightning__textType", "Final Competitor", "Optional picklist: AlphaSense, BlueFlame, ChatGPT, Claude, Hebbia, Internal Build, ModelML, Perplexity."),
    ("notes", "lightning__textType", "CL Notes", "Why the deal was lost. Defaults to the AI narrative when blank."),
    ("lobDivision", "lightning__textType", "LOB/Division", "Required picklist: Investment Banking, Commercial Banking, Corporate Banking, Corporate Finance, Wealth Management, Asset Management, Private Equity, Private Credit, Hedge Fund, Venture Capital / Ventures, Corporate Development, Sales & Trading / Markets."),
]
w(f"{PKG}/genAiFunctions/Submit_Closed_Lost/Submit_Closed_Lost.genAiFunction-meta.xml", action_meta(
    "Closes an Opportunity as Closed Lost the way the Close Opportunity screen flow does. Without confirm it returns the AI-recommended loss reason, competitor, and narrative plus a preview; with confirm it stamps Closed Lost with the reasons, notes, and LOB/Division. Blank inputs keep existing values.",
    "SubmitClosedLost", "Submit Closed Lost", "Analyzing the loss..."))
w(f"{PKG}/genAiFunctions/Submit_Closed_Lost/input/schema.json", action_input(LOST_INPUTS, ["opportunityId"]))
w(f"{PKG}/genAiFunctions/Submit_Closed_Lost/output/schema.json", action_output(SUBMISSION))

# ─── Picklist value 'Agent' on CW_Submission_Source__c ───────────────────

w(f"{PKG}/objects/Opportunity/fields/CW_Submission_Source__c.field-meta.xml", """<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>CW_Submission_Source__c</fullName>
    <externalId>false</externalId>
    <label>CW Submission Source</label>
    <required>false</required>
    <trackFeedHistory>false</trackFeedHistory>
    <trackHistory>false</trackHistory>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value>
                <fullName>Felix</fullName>
                <default>false</default>
                <label>Felix</label>
            </value>
            <value>
                <fullName>Screen Flow</fullName>
                <default>false</default>
                <label>Screen Flow</label>
            </value>
            <value>
                <fullName>Slack</fullName>
                <default>false</default>
                <label>Slack</label>
            </value>
            <value>
                <fullName>Agent</fullName>
                <default>false</default>
                <label>Agent</label>
            </value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
""")

# ─── MCP server definition: existing tool + three new ────────────────────

def tool_xml(cls, title, desc, ui_resource, read_only):
    return f"""    <tools>
        <apiDefinition>
            <apiIdentifier>aa:apex-{cls}</apiIdentifier>
            <apiSource>API_CATALOG</apiSource>
            <operation>{cls}</operation>
        </apiDefinition>
        <descriptionOverride>{desc}</descriptionOverride>
        <destructive>false</destructive>
        <idempotent>{'true' if read_only else 'false'}</idempotent>
        <openWorld>false</openWorld>
        <readOnly>{'true' if read_only else 'false'}</readOnly>
        <returnDirect>false</returnDirect>
        <toolName>{cls}apex_{cls}</toolName>
        <toolTitle>{title}</toolTitle>
        <uiResource>{ui_resource}</uiResource>
    </tools>
"""

def resource_xml(name, clt, title, desc):
    return f"""    <resources>
        <resourceName>{name}</resourceName>
        <resourceUri>ui://widget/lightningType/c__{clt}</resourceUri>
        <resourceTitle>{title}</resourceTitle>
        <description>{desc}</description>
    </resources>
"""

server = ('<?xml version="1.0" encoding="UTF-8"?>\n<McpServerDefinition xmlns="http://soap.sforce.com/2006/04/metadata">\n'
          '    <description>HXL Account Widget</description>\n    <masterLabel>HXL-Accounts</masterLabel>\n'
    + tool_xml("GetAccountSummary", "Get Account Summary",
               "Returns a summary of a Salesforce account: firmographics, owner, location, contact count, open pipeline totals, and the top open opportunities. Provide the Account Id (starts with 001). The result renders as an account summary card.",
               "accountSummaryCard", True)
    + tool_xml("GetCloseReadiness", "Get Close Readiness",
               "Checks whether an Opportunity can be closed: whether a signed order form is attached and which Closed Won fields still need values. Read-only. Call this first when a user wants to close a deal. Provide the Opportunity Id (starts with 006).",
               "closeReadinessCard", True)
    + tool_xml("SubmitClosedWon", "Submit Closed Won",
               "Submits an Opportunity as Closed Won like the Close Opportunity screen flow. Call without confirm to validate and preview; the user reviews the card, then call again with confirm=true to write the finance and handoff fields, notify RevOps in Slack, and queue order form extraction. RevOps stamps the stage. Requires a signed order form on the record. Blank inputs keep existing values, and a blank LOB/Division defaults from the account type. When fields are missing, ask the user for all of them in one message rather than one at a time.",
               "closeSubmissionCardWon", False)
    + tool_xml("SubmitClosedLost", "Submit Closed Lost",
               "Closes an Opportunity as Closed Lost like the Close Opportunity screen flow. Call without confirm to preview: the first call starts the AI loss analysis in the background (about 30 seconds) and returns immediately; a later preview call shows the recommended reason, competitor, and narrative. The user reviews the card, then call again with confirm=true to stamp Closed Lost. Blank inputs keep existing values; blank notes default to the AI narrative; a blank LOB/Division defaults from the account type. When fields are missing, ask the user for all of them in one message rather than one at a time.",
               "closeSubmissionCardLost", False)
    + resource_xml("accountSummaryCard", "getAccountSummary", "Account Summary Card",
                   "HXL widget that renders an account summary: header with industry and type, firmographics, owner and location, open pipeline with top opportunities, and a link to the record.")
    + resource_xml("closeReadinessCard", "getCloseReadiness", "Close Readiness Card",
                   "HXL widget showing whether an opportunity can be closed: status, signed order form check, Closed Won field checklist, and buttons to start Closed Won or Closed Lost.")
    + resource_xml("closeSubmissionCardWon", "submitClosedWon", "Closed Won Submission Card",
                   "HXL widget showing the preview, validation problems, or result of a Closed Won submission, with confirm and change buttons.")
    + resource_xml("closeSubmissionCardLost", "submitClosedLost", "Closed Lost Submission Card",
                   "HXL widget showing the AI recommendation, preview, validation problems, or result of a Closed Lost submission, with confirm and change buttons.")
    + "</McpServerDefinition>\n")
w(f"{PKG}/mcpServerDefinitions/HXLAccounts.mcpServerDefinition-meta.xml", server)
print("generated")
