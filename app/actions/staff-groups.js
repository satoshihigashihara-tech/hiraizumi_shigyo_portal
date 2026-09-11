"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import {
  parseRoomPlan, readGroupReviewFields, reviewFailure, revisionDeadline,
  validateReason, validateReviewIdentity,
} from "@/utils/community-groups/review";
import { isUpdatedAt } from "@/utils/community-groups/validation";

function refresh(groupId) {
  for (const path of ["/staff", "/staff/community", "/staff/community/groups", `/staff/community/groups/${groupId}`,
    "/staff/calendar", "/calendar", "/user", "/user/groups", `/user/groups/${groupId}`]) revalidatePath(path);
}

async function groupAction(formData, action) {
  const { supabase } = await requireStaff("/staff/community/groups");
  const fields = readGroupReviewFields(formData);
  const invalid = validateReviewIdentity(fields);
  if (invalid) return reviewFailure(invalid, fields);
  const reasonError = validateReason(fields.reason, action === "reject");
  if (reasonError) return reviewFailure(reasonError, fields);
  const { data, error } = await supabase.rpc("review_group_application", {
    target_group_id: fields.groupId, review_action: action, expected_updated_at: fields.updatedAt,
    public_reason: fields.reason || null,
  });
  if (error) return reviewFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  const expected = { confirm_purpose: "under_review", reject: "rejected", approve: "approved" }[action];
  if (result?.result_id !== fields.groupId || result?.result_status !== expected || !isUpdatedAt(result?.result_updated_at)) return reviewFailure("update-failed", fields);
  refresh(fields.groupId); redirect(`/staff/community/groups/${fields.groupId}?updated=${action}`);
}

export async function confirmCommunityGroupPurpose(formData) { return groupAction(formData, "confirm_purpose"); }
export async function rejectCommunityGroup(formData) { return groupAction(formData, "reject"); }
export async function approveCommunityGroup(formData) { return groupAction(formData, "approve"); }

export async function setCommunityGroupRooms(formData) {
  const { supabase } = await requireStaff("/staff/community/groups");
  const fields = readGroupReviewFields(formData); const invalid = validateReviewIdentity(fields);
  if (invalid) return reviewFailure(invalid, fields);
  const roomPlan = parseRoomPlan(fields.roomPlan); if (!roomPlan) return reviewFailure("invalid-room-plan", fields);
  const reasonError = validateReason(fields.reason); if (reasonError) return reviewFailure(reasonError, fields);
  const { data, error } = await supabase.rpc("set_group_room_allocations", { target_group_id: fields.groupId,
    expected_updated_at: fields.updatedAt, room_plan: roomPlan, change_reason: fields.reason || null });
  if (error) return reviewFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.groupId || !["under_review", "approved"].includes(result?.result_status)
    || !isUpdatedAt(result?.result_updated_at)) return reviewFailure("update-failed", fields);
  refresh(fields.groupId); redirect(`/staff/community/groups/${fields.groupId}?updated=rooms`);
}

async function participantAction(formData, action) {
  const { supabase } = await requireStaff("/staff/community/groups");
  const fields = readGroupReviewFields(formData); const invalid = validateReviewIdentity(fields, true);
  if (invalid) return reviewFailure(invalid, fields);
  const reasonError = validateReason(fields.reason, action === "request_revision");
  if (reasonError) return reviewFailure(reasonError, fields);
  const deadline = action === "request_revision" ? revisionDeadline(fields.revisionDeadline) : null;
  if (action === "request_revision" && !deadline) return reviewFailure("invalid-deadline", fields);
  const { data, error } = await supabase.rpc("review_group_participant", { target_application_id: fields.applicationId,
    review_action: action, expected_updated_at: fields.updatedAt, public_reason: fields.reason || null,
    revision_deadline: deadline });
  if (error) return reviewFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  const expected = { start_review: "under_review", request_revision: "revision_requested", approve: "approved" }[action];
  if (result?.result_id !== fields.applicationId || result?.result_group_id !== fields.groupId
    || result?.result_status !== expected || !isUpdatedAt(result?.result_updated_at)) return reviewFailure("update-failed", fields);
  refresh(fields.groupId); redirect(`/staff/community/groups/${fields.groupId}?updated=participant-${action}`);
}

export async function startCommunityGroupParticipantReview(formData) { return participantAction(formData, "start_review"); }
export async function requestCommunityGroupParticipantRevision(formData) { return participantAction(formData, "request_revision"); }
export async function approveCommunityGroupParticipant(formData) { return participantAction(formData, "approve"); }
