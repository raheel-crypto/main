# Red Team Agent

Stateless evaluator that role-plays adversaries against advanced-stage deals.
Receives intel packs from Merlin (the Slack bot), returns structured
persona arguments. Merlin owns the Slack UX + audit; this service is pure
evaluation.

## Contract

- **Source of truth**: `slack-bot/src/types.ts` (`RedTeamIntelPackRequest`,
  `RedTeamRunResult`). The Pydantic mirrors in `app/schemas.py` must stay in
  sync — when Merlin's contract changes, update both sides together.
- **Auth**: HMAC-SHA256 over `<timestamp>.<body>` using
  `RED_TEAM_AGENT_SECRET`. See `app/auth.py` (verify) and
  `slack-bot/src/services/redTeamClient.ts:signBody` (sign).

## Run locally

```bash
cd red-team-agent
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # generate a secret with: openssl rand -hex 32
uvicorn app.main:app --reload --port 3003
```

Then hit it from Merlin by setting in `~/sf-visualizer/.env`:

```
RED_TEAM_AGENT_URL=http://localhost:3003
RED_TEAM_AGENT_SECRET=<same value>
RED_TEAM_SHADOW_MODE=true
RED_TEAM_STAGE_ALLOWLIST=Stage 4 - Demo,Stage 5 - Proposal
```

## Smoke test the contract end-to-end

```bash
# 1. Run a probe in slack-bot to dump a real intel pack as JSON.
cd slack-bot
npm run probe red-team-pack <slack_user_id> <opportunity_id> > /tmp/pack.json

# 2. Sign it and POST to the local Python service. (`openssl rand -hex 32`
#    once, then use that value in both env vars.)
cd ../red-team-agent
python - <<'PY'
import hashlib, hmac, json, os, time, urllib.request
secret = os.environ["RED_TEAM_AGENT_SECRET"].encode()
body = open("/tmp/pack.json", "rb").read()
ts = str(int(time.time()))
sig = hmac.new(secret, f"{ts}.".encode() + body, hashlib.sha256).hexdigest()
req = urllib.request.Request(
    "http://localhost:3003/evaluate",
    data=body,
    headers={
        "Content-Type": "application/json",
        "X-RedTeam-Timestamp": ts,
        "X-RedTeam-Signature": sig,
    },
)
print(urllib.request.urlopen(req).read().decode())
PY
```

## Tests

```bash
pytest -q
```

The fixture `tests/fixtures/sample_pack.json` is a minimal valid intel pack
you can use to iterate without running probes against real Salesforce.

## Where to drop your existing logic

| Existing file        | Goes into                                     |
| -------------------- | --------------------------------------------- |
| `dead_deals.json` etc. | `intel/` (referenced by `runner.py`)        |
| Persona Markdown    | `prompts/<persona_id>.md`                     |
| Trigger YAML rules  | `config/triggers.yaml` (+ `app/triggers.py`)  |
| Anthropic SDK call  | `app/runner.py:invoke_persona`                |
| Persona selection   | `app/personas.py:TRIGGER_TO_PERSONAS`         |

The boundary code in `app/main.py`, `app/auth.py`, and `app/schemas.py`
should not need to change as you fill those in.

## Deploy (Vercel)

This service deploys as its own Vercel project, separate from the slack-bot
project but sharing the same Postgres database. Cooldown state lives in the
`red_team_cooldowns` table (slack-bot owns the migration).

One-time setup:

1. From the Vercel dashboard, **Add New… → Project** and import this repo.
2. Set the **Root Directory** to `red-team-agent`.
3. **Environment variables** (Production + Preview):
   - `RED_TEAM_AGENT_SECRET` — same value as on the slack-bot project
   - `ANTHROPIC_API_KEY`
   - `POSTGRES_URL` — paste the connection string from the slack-bot project
     (or attach the same Vercel Postgres store to this project — it injects
     `POSTGRES_URL` automatically).
4. **Deploy**. Vercel reads `vercel.json`, routes every path to
   `api/index.py`, which re-exports the FastAPI app from `app/main.py`.

After deploy, on the **slack-bot project** set
`RED_TEAM_AGENT_URL=https://<this-project>.vercel.app`.

### Verifying the deploy

```bash
curl https://<this-project>.vercel.app/health
# → {"ok":"true","service":"red-team-agent"}
```

Then from slack-bot:

```bash
npm run probe -w slack-bot red-team <slack_user_id> <opportunity_id>
```

The probe assembles a real intel pack, POSTs it through Merlin's
HMAC-signed client, and prints the agent's response (or the cooldown drop
reason on a second invocation).

### Docker / VM (fallback)

If you ever need a single always-warm instance, `docker build .` still
works — set `POSTGRES_URL` the same way and skip `RED_TEAM_STATE_DIR`
(unused with the Postgres backend).

## Rollout knobs (driven by Merlin)

Merlin controls who gets DMs and when via env vars on the slack-bot
deployment — nothing to configure here:

- `RED_TEAM_SHADOW_MODE` — Merlin audits but doesn't post.
- `RED_TEAM_REDIRECT_TO_SLACK_USER_ID` — all DMs go to one human during
  the manager-only rollout step.
- `RED_TEAM_STAGE_ALLOWLIST` — which `StageName` values are eligible.

This service just evaluates whatever Merlin sends it.
