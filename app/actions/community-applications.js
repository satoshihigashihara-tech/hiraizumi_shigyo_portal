"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";
import { getText, isDate } from "@/utils/calendar/validation";
import { readFields, toDatabaseFields, validateFields, communityFailure, booleanField, isUuid, isUpdatedAt, FIELD_NAMES } from "@/utils/community-applications/validation";

const START_PATH = "/user/applications/new/community-activity";
function refresh(applicationId) {
  for (const path of ["/user", "/user/applications", "/calendar", "/staff", "/staff/calendar", "/staff/community", "/staff/community/applications",
    `/staff/community/applications/${applicationId}`, `/user/applications/${applicationId}`,
    `/user/applications/${applicationId}/edit`, `/user/applications/${applicationId}/confirm`, `/user/applications/${applicationId}/complete`]) revalidatePath(path);
}

async function save(formData, creating) {
  const { supabase } = await requireActiveUser(START_PATH);
  const fields = readFields(formData);
  if (!isUuid(fields.applicationId)) return communityFailure("invalid-application", fields);
  if (!creating && !isUpdatedAt(fields.updatedAt)) return communityFailure("invalid-version", fields);
  // Omitted initial fields retain profile defaults. Later saves replace all editable fields.
  const initialFields = Object.fromEntries(Object.keys(FIELD_NAMES).filter((name) => formData.has(name)).map((name) => [name, fields[name]]));
  const fieldErrors = validateFields(creating ? initialFields : fields);
  if (Object.keys(fieldErrors).length) return communityFailure(Object.values(fieldErrors)[0], fields, fieldErrors);
  const input = { target_application_id: fields.applicationId, draft_fields: toDatabaseFields(creating ? initialFields : fields, creating) };
  if (!creating) input.expected_updated_at = fields.updatedAt;
  const { data, error } = await supabase.rpc(creating ? "create_community_application_draft" : "save_community_application_draft", input);
  if (error) return communityFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.applicationId || !isUpdatedAt(result?.result_updated_at)) return communityFailure("update-failed", fields);
  refresh(fields.applicationId);
  redirect(`/user/applications/${fields.applicationId}/${fields.intent === "confirm" ? "confirm" : "edit?saved=1"}`);
}
export async function createCommunityApplicationDraft(formData) { return save(formData, true); }
export async function saveCommunityApplicationDraft(formData) { return save(formData, false); }
export async function submitCommunityApplication(formData) {
  const { supabase } = await requireActiveUser(START_PATH);
  const fields = readFields(formData);
  if (!isUuid(fields.applicationId)) return communityFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return communityFailure("invalid-version", fields);
  if (!isUuid(fields.submissionKey)) return communityFailure("invalid-submission-key", fields);
  if (booleanField(fields.confirmed) !== true) return communityFailure("confirmation-required", fields);
  const { data, error } = await supabase.rpc("submit_community_application", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    submission_key: fields.submissionKey, confirmed: true,
  });
  if (error) return communityFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.applicationId || !isUpdatedAt(result?.result_updated_at)
    || !/^SG-\d{4}-\d{4,}$/.test(result?.reception_number ?? "") || !isUpdatedAt(result?.submission_time)) return communityFailure("update-failed", fields);
  refresh(fields.applicationId);
  redirect(`/user/applications/${fields.applicationId}/complete`);
}

export async function requestCommunityApplicationCancellation(formData) {
  const { supabase } = await requireActiveUser("/user/applications");
  const fields = Object.fromEntries(["applicationId", "updatedAt", "reason"].map((key) => [key, getText(formData, key)]));
  if (!isUuid(fields.applicationId)) return communityFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return communityFailure("invalid-version", fields);
  const reason = fields.reason.trim();
  if (!reason) return communityFailure("reason-required", fields);
  if (Array.from(reason).length > 2000) return communityFailure("reason-too-long", fields);
  const { data, error } = await supabase.rpc("request_community_application_cancellation", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    cancellation_reason: reason,
  });
  if (error) return communityFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.applicationId || result?.result_status !== "cancellation_requested"
    || !isUpdatedAt(result?.result_updated_at)) return communityFailure("update-failed", fields);
  refresh(fields.applicationId);
  redirect(`/user/applications/${fields.applicationId}?updated=cancellation-requested`);
}

export async function createCommunityApplicationExtension(formData) {
  const { supabase } = await requireActiveUser("/user/applications");
  const fields = Object.fromEntries(["extensionId", "originalApplicationId", "endDate", "reason"]
    .map((key) => [key, getText(formData, key)]));
  if (!isUuid(fields.extensionId) || !isUuid(fields.originalApplicationId)) return communityFailure("invalid-application", fields);
  if (!isDate(fields.endDate)) return communityFailure("invalid-extension-period", fields);
  const reason = fields.reason.trim();
  if (!reason) return communityFailure("reason-required", fields);
  if (Array.from(reason).length > 2000) return communityFailure("reason-too-long", fields);
  const { data, error } = await supabase.rpc("create_community_application_extension", {
    target_extension_id: fields.extensionId, target_original_application_id: fields.originalApplicationId,
    target_end_date: fields.endDate, extension_reason_value: reason,
  });
  if (error) return communityFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.extensionId || !isUpdatedAt(result?.result_updated_at)) return communityFailure("update-failed", fields);
  refresh(fields.extensionId);
  redirect(`/user/applications/${fields.extensionId}/edit?created=extension`);
}
