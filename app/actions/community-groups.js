"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";
import { withMode } from "@/utils/navigation/mode";
import {
  GROUP_FIELD_NAMES, booleanField, groupFailure, isUpdatedAt, isUuid, readGroupFields,
  toGroupDatabaseFields, validateGroupFields,
} from "@/utils/community-groups/validation";

const START_PATH = withMode("/user/groups/new", "fieldwork");

function refresh(groupId) {
  for (const path of ["/user", "/user/groups", "/calendar", "/staff", "/staff/calendar",
    `/user/groups/${groupId}`, `/user/groups/${groupId}/edit`, `/user/groups/${groupId}/confirm`,
    `/user/groups/${groupId}/complete`]) revalidatePath(path);
}

async function save(formData, creating) {
  const { supabase } = await requireActiveUser(START_PATH);
  const fields = readGroupFields(formData);
  if (!isUuid(fields.groupId)) return groupFailure("invalid-group", fields);
  if (!creating && !isUpdatedAt(fields.updatedAt)) return groupFailure("invalid-version", fields);
  const initialFields = Object.fromEntries(Object.keys(GROUP_FIELD_NAMES)
    .filter((name) => formData.has(name)).map((name) => [name, fields[name]]));
  const checked = creating ? initialFields : fields;
  const fieldErrors = validateGroupFields(checked);
  if (Object.keys(fieldErrors).length) return groupFailure(Object.values(fieldErrors)[0], fields, fieldErrors);
  const input = { target_group_id: fields.groupId, draft_fields: toGroupDatabaseFields(checked, creating) };
  if (!creating) input.expected_updated_at = fields.updatedAt;
  const { data, error } = await supabase.rpc(creating ? "create_community_group_draft" : "save_community_group_draft", input);
  if (error) return groupFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.groupId || !isUpdatedAt(result?.result_updated_at)) return groupFailure("update-failed", fields);
  refresh(fields.groupId);
  redirect(withMode(`/user/groups/${fields.groupId}/${fields.intent === "confirm" ? "confirm" : "edit?saved=1"}`, "fieldwork"));
}

export async function createCommunityGroupDraft(formData) { return save(formData, true); }
export async function saveCommunityGroupDraft(formData) { return save(formData, false); }

export async function startCommunityGroupApplication(formData) {
  const { supabase } = await requireActiveUser(START_PATH);
  const fields = readGroupFields(formData);
  if (!isUuid(fields.groupId)) return groupFailure("invalid-group", fields);
  if (!isUpdatedAt(fields.updatedAt)) return groupFailure("invalid-version", fields);
  if (!isUuid(fields.submissionKey)) return groupFailure("invalid-submission-key", fields);
  if (booleanField(fields.confirmed) !== true) return groupFailure("confirmation-required", fields);
  const { data, error } = await supabase.rpc("start_community_group_application", {
    target_group_id: fields.groupId, expected_updated_at: fields.updatedAt,
    submission_key: fields.submissionKey, confirmed: true,
  });
  if (error) return groupFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.groupId || result?.result_status !== "collecting"
    || !isUpdatedAt(result?.result_updated_at) || !isUpdatedAt(result?.submission_time)
    || !isUpdatedAt(result?.participant_due_at) || !/^SG-\d{4}-\d{4,}$/.test(result?.reception_number ?? "")) {
    return groupFailure("update-failed", fields);
  }
  refresh(fields.groupId);
  redirect(withMode(`/user/groups/${fields.groupId}/complete`, "fieldwork"));
}

export async function requestCommunityGroupCancellation(formData) {
  const { supabase } = await requireActiveUser(withMode("/user/groups", "fieldwork"));
  const fields = readGroupFields(formData);
  if (!isUuid(fields.groupId)) return groupFailure("invalid-group", fields);
  if (!isUpdatedAt(fields.updatedAt)) return groupFailure("invalid-version", fields);
  if (booleanField(fields.confirmed) !== true) return groupFailure("confirmation-required", fields);
  if (!fields.reason.trim()) return groupFailure("reason-required", fields);
  if (Array.from(fields.reason.trim()).length > 2000) return groupFailure("reason-too-long", fields);
  const { data, error } = await supabase.rpc("request_community_group_cancellation", {
    target_group_id: fields.groupId, expected_updated_at: fields.updatedAt, cancellation_reason: fields.reason,
  });
  if (error) return groupFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.groupId || result?.result_status !== "cancellation_requested"
    || !isUpdatedAt(result?.result_updated_at)) return groupFailure("update-failed", fields);
  refresh(fields.groupId);
  redirect(withMode(`/user/groups/${fields.groupId}?updated=cancellation-requested`, "fieldwork"));
}
