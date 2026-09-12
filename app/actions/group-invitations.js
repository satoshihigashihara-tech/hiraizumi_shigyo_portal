"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";
import { inviteFailure, isUpdatedAt, isUuid, normalizeInvite, readInviteFields } from "@/utils/group-invitations/validation";
import { validateReason } from "@/utils/community-groups/review";

function refresh(groupId, applicationId = null) {
  for (const path of ["/user", "/user/groups", `/user/groups/${groupId}`, `/user/groups/${groupId}/participants`]) {
    revalidatePath(path);
  }
  if (applicationId) {
    revalidatePath("/user/applications"); revalidatePath(`/user/applications/${applicationId}`);
    revalidatePath(`/user/applications/${applicationId}/edit`);
  }
}

export async function issueCommunityGroupInvite(formData) {
  const { supabase } = await requireActiveUser("/user/groups");
  const fields = readInviteFields(formData);
  if (!isUuid(fields.groupId)) return inviteFailure("invalid-group", fields);
  if (!isUpdatedAt(fields.updatedAt)) return inviteFailure("invalid-version", fields);
  const { data, error } = await supabase.rpc("issue_community_group_invite", {
    target_group_id: fields.groupId, expected_updated_at: fields.updatedAt,
  });
  if (error) return inviteFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_group_id !== fields.groupId || !isUpdatedAt(result?.result_updated_at)
    || !normalizeInvite(result?.invite_token, "token") || !normalizeInvite(result?.invite_code, "code")
    || !isUpdatedAt(result?.expires_at)) return inviteFailure("update-failed", fields);
  refresh(fields.groupId);
  return { error: null, fields: {}, fieldErrors: {}, invite: {
    token: result.invite_token, code: result.invite_code,
    expiresAt: result.expires_at, groupUpdatedAt: result.result_updated_at,
  } };
}

export async function joinCommunityGroup(formData) {
  const { supabase } = await requireActiveUser("/invite");
  const fields = readInviteFields(formData);
  if (!isUuid(fields.applicationId)) return inviteFailure("invalid-application", fields);
  if (fields.confirmed !== "true") return inviteFailure("confirmation-required", fields);
  const inviteValue = normalizeInvite(fields.inviteValue, fields.inviteKind);
  if (!inviteValue) return inviteFailure("invalid-invite", fields);
  const { data, error } = await supabase.rpc("join_community_group", {
    invite_value: inviteValue, invite_kind: fields.inviteKind, target_application_id: fields.applicationId,
  });
  if (error) return inviteFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (!isUuid(result?.result_group_id) || !isUuid(result?.result_application_id)
    || !isUpdatedAt(result?.result_group_updated_at)) return inviteFailure("update-failed", fields);
  refresh(result.result_group_id, result.result_application_id);
  redirect(`/user/applications/${result.result_application_id}/edit?joined=group`);
}

export async function removeCommunityGroupParticipant(formData) {
  const { supabase } = await requireActiveUser("/user/groups");
  const fields = readInviteFields(formData);
  if (!isUuid(fields.groupId)) return inviteFailure("invalid-group", fields);
  if (!isUuid(fields.applicationId)) return inviteFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return inviteFailure("invalid-version", fields);
  if (fields.confirmed !== "true") return inviteFailure("confirmation-required", fields);
  const reasonError = validateReason(fields.reason, true);
  if (reasonError) return inviteFailure(reasonError, fields);
  const { data, error } = await supabase.rpc("remove_community_group_participant", {
    target_group_id: fields.groupId, target_application_id: fields.applicationId,
    expected_updated_at: fields.updatedAt, removal_reason: fields.reason,
  });
  if (error) return inviteFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_group_id !== fields.groupId || result?.result_application_status !== "cancelled"
    || !["collecting"].includes(result?.result_group_status) || !isUpdatedAt(result?.result_group_updated_at)) {
    return inviteFailure("update-failed", fields);
  }
  refresh(fields.groupId, fields.applicationId);
  redirect(`/user/groups/${fields.groupId}/participants?updated=participant-removed`);
}
