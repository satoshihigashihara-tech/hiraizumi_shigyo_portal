import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";
import { isUuid, participantErrorCode, PARTICIPANT_FIELDS } from "@/utils/group-participants/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row?.[key] ?? null]));
export async function getGroupParticipantApplication(applicationId, mode = "detail") {
  const { supabase } = await requireActiveUser("/user/applications");
  if (!isUuid(applicationId) || !["detail", "edit", "confirm", "complete"].includes(mode)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_group_participant_application", { target_application_id: applicationId });
  if (error) return { error: participantErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (!data || data.id !== applicationId || !data.fields || !isUuid(data.group_id)) return { error: "load-failed", application: null };
  const application = pick(data, ["id", "group_id", "group_name", "group_status", "status", "updated_at", "start_date", "end_date",
    "usage_place", "purpose", "local_activity", "participant_due_at", "revision_due_at", "active_deadline", "decision_reason",
    "submitted_at", "last_submitted_at", "reception_number", "has_consent", "can_edit"]);
  application.fields = pick(data.fields, Object.values(PARTICIPANT_FIELDS));
  if (mode === "complete" && (!data.submitted_at || !data.reception_number)) return { error: "not-submittable", application: null };
  if (["edit", "confirm"].includes(mode) && !data.can_edit) return { error: data.validation_error || "not-editable", application };
  if (mode === "confirm" && data.validation_error) return { error: participantErrorCode(data.validation_error), application };
  return { error: null, application };
}
