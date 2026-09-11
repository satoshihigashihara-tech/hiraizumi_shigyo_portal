"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";
import { booleanField, isUpdatedAt, isUuid, participantFailure, readParticipantFields,
  toParticipantDatabaseFields, validateParticipantFields } from "@/utils/group-participants/validation";

function refresh(applicationId, groupId) {
  const paths = ["/user/applications", `/user/applications/${applicationId}`,
    `/user/applications/${applicationId}/edit`, `/user/applications/${applicationId}/confirm`,
    `/user/applications/${applicationId}/complete`, "/user/groups"];
  if (isUuid(groupId)) paths.push(`/user/groups/${groupId}`, `/user/groups/${groupId}/participants`);
  for (const path of paths) revalidatePath(path);
}

export async function saveGroupParticipantApplication(formData) {
  const { supabase } = await requireActiveUser("/user/applications");
  const fields = readParticipantFields(formData);
  if (!isUuid(fields.applicationId)) return participantFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return participantFailure("invalid-version", fields);
  const fieldErrors = validateParticipantFields(fields);
  if (Object.keys(fieldErrors).length) return participantFailure(Object.values(fieldErrors)[0], fields, fieldErrors);
  const { data, error } = await supabase.rpc("save_group_participant_application", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    draft_fields: toParticipantDatabaseFields(fields),
  });
  if (error) return participantFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.applicationId || !isUpdatedAt(result?.result_updated_at)) return participantFailure("update-failed", fields);
  refresh(fields.applicationId, null);
  redirect(`/user/applications/${fields.applicationId}/${fields.intent === "confirm" ? "confirm" : "edit?saved=1"}`);
}

export async function submitGroupParticipantApplication(formData) {
  const { supabase } = await requireActiveUser("/user/applications");
  const fields = readParticipantFields(formData);
  if (!isUuid(fields.applicationId)) return participantFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return participantFailure("invalid-version", fields);
  if (!isUuid(fields.submissionKey)) return participantFailure("invalid-submission-key", fields);
  if (booleanField(fields.confirmed) !== true) return participantFailure("confirmation-required", fields);
  const { data, error } = await supabase.rpc("submit_group_participant_application", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    submission_key: fields.submissionKey, confirmed: true,
  });
  if (error) return participantFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.applicationId || result?.result_status !== "submitted"
    || !isUpdatedAt(result?.result_updated_at) || !isUpdatedAt(result?.submission_time)
    || !/^SG-\d{4}-\d{4,}$/.test(result?.reception_number ?? "") || !isUuid(result?.result_group_id)
    || !["collecting", "under_review"].includes(result?.result_group_status)
    || !isUpdatedAt(result?.result_group_updated_at)) return participantFailure("update-failed", fields);
  refresh(fields.applicationId, result.result_group_id);
  redirect(`/user/applications/${fields.applicationId}/complete`);
}
