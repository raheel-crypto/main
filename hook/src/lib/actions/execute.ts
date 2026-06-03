import { sql } from "@/lib/db/client";
import { updateAccountArr, setOppLocked } from "@/lib/salesforce/writes";
import type { ActionKind } from "./propose";

export interface PendingActionRow {
  id: number;
  kind: ActionKind;
  account_id: string | null;
  opportunity_id: string | null;
  target_object: string;
  target_field: string;
  current_value: string;
  proposed_value: string;
  button_text: string;
  confirm_text: string;
  applied_at: string | null;
  applied_by_slack_user_id: string | null;
}

export async function loadAction(actionId: number): Promise<PendingActionRow | null> {
  const rows = (await sql`
    SELECT id, kind, account_id, opportunity_id, target_object, target_field,
           current_value, proposed_value, button_text, confirm_text,
           applied_at, applied_by_slack_user_id
    FROM pending_actions
    WHERE id = ${actionId}
    LIMIT 1
  `) as PendingActionRow[];
  return rows[0] ?? null;
}

export interface ExecuteResult {
  ok: boolean;
  error?: string;
}

export async function executeAction(
  action: PendingActionRow,
  slackUserId: string,
  slackUserName: string,
): Promise<ExecuteResult> {
  try {
    switch (action.kind) {
      case "sync_account_arr": {
        if (!action.account_id) throw new Error("Missing account_id");
        const newArr = Number(action.proposed_value);
        if (Number.isNaN(newArr)) throw new Error(`Bad proposed value: ${action.proposed_value}`);
        await updateAccountArr(action.account_id, newArr);
        break;
      }
      case "lock_opp": {
        if (!action.opportunity_id) throw new Error("Missing opportunity_id");
        await setOppLocked(action.opportunity_id, action.proposed_value === "true");
        break;
      }
      default: {
        const _exhaustive: never = action.kind;
        throw new Error(`Unknown action kind: ${_exhaustive}`);
      }
    }

    await sql`
      UPDATE pending_actions
      SET applied_at = NOW(),
          applied_by_slack_user_id = ${slackUserId},
          applied_by_slack_user_name = ${slackUserName},
          result = 'success'
      WHERE id = ${action.id}
    `;

    return { ok: true };
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    await sql`
      UPDATE pending_actions
      SET applied_at = NOW(),
          applied_by_slack_user_id = ${slackUserId},
          applied_by_slack_user_name = ${slackUserName},
          result = 'error',
          error_message = ${errorMessage}
      WHERE id = ${action.id}
    `;
    return { ok: false, error: errorMessage };
  }
}
