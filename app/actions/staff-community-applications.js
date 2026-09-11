"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { getText, toTokyoDeadline, reasonError } from "@/utils/calendar/validation";
import { communityFailure, isUuid, isUpdatedAt } from "@/utils/community-applications/validation";

async function review(formData, operation) {
  const { supabase } = await requireStaff("/staff/community/applications");
  const fields = Object.fromEntries(["applicationId", "updatedAt", "reason", "revisionDeadline", "roomId", "approvalComment"].map((key) => [key, getText(formData, key)]));
  const failure = (error) => {
    const result = communityFailure(error, fields);
    if (operation === "approve" && result.fieldErrors.reason) {
      result.fieldErrors.approvalComment = result.fieldErrors.reason;
      delete result.fieldErrors.reason;
    }
    return result;
  };
  if (!isUuid(fields.applicationId)) return failure("invalid-application");
  if (!isUpdatedAt(fields.updatedAt)) return failure("invalid-version");
  const reason = operation === "approve" ? fields.approvalComment : fields.reason;
  const invalidReason = reasonError(reason, ["request_revision", "reject"].includes(operation));
  if (invalidReason) return failure(invalidReason);
  if (operation === "assign_room" && !isUuid(fields.roomId)) return failure("invalid-room");
  const deadline = operation === "request_revision" && fields.revisionDeadline ? toTokyoDeadline(fields.revisionDeadline) : null;
  if (operation === "request_revision" && fields.revisionDeadline && !deadline) return failure("invalid-deadline");
  const input = { target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt };
  if (operation === "assign_room") {
    input.target_room_id = fields.roomId;
    input.change_reason = reason || null;
  } else {
    input.review_action = operation;
    input.public_reason = operation === "start_review" ? null : reason || null;
    input.revision_deadline = deadline;
  }
  const { data, error } = await supabase.rpc(operation === "assign_room" ? "assign_community_application_room" : "review_community_application", input);
  if (error) return failure(error);
  const result = Array.isArray(data) ? data[0] : null;
  const expectedStatuses = { start_review: ["under_review"], request_revision: ["revision_requested"], reject: ["rejected"],
    approve: ["approved"], assign_room: ["under_review", "approved"] }[operation];
  if (result?.result_id !== fields.applicationId || !expectedStatuses.includes(result.result_status) || !isUpdatedAt(result.result_updated_at)) return failure("update-failed");
  const path = `/staff/community/applications/${fields.applicationId}`;
  for (const route of [path, "/staff", "/staff/community", "/staff/community/applications", "/staff/calendar", "/calendar", "/user", "/user/applications",
    `/user/applications/${fields.applicationId}`, `/user/applications/${fields.applicationId}/edit`, `/user/applications/${fields.applicationId}/confirm`,
    `/user/applications/${fields.applicationId}/complete`]) revalidatePath(route);
  redirect(`${path}?updated=${operation === "assign_room" ? "room-assigned" : result.result_status}`);
}
export async function startCommunityApplicationReview(formData) { return review(formData, "start_review"); }
export async function requestCommunityApplicationRevision(formData) { return review(formData, "request_revision"); }
export async function rejectCommunityApplication(formData) { return review(formData, "reject"); }
export async function assignCommunityApplicationRoom(formData) { return review(formData, "assign_room"); }
export async function approveCommunityApplication(formData) { return review(formData, "approve"); }

export async function confirmCommunityApplicationCancellation(formData) {
  const { supabase } = await requireStaff("/staff/community/applications");
  const fields = Object.fromEntries(["applicationId", "updatedAt", "reason"].map((key) => [key, getText(formData, key)]));
  if (!isUuid(fields.applicationId)) return communityFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return communityFailure("invalid-version", fields);
  const reason = fields.reason.trim();
  const invalidReason = reasonError(reason, true);
  if (invalidReason) return communityFailure(invalidReason, fields);
  const { data, error } = await supabase.rpc("confirm_community_application_cancellation", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    confirmation_reason: reason,
  });
  if (error) return communityFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (result?.result_id !== fields.applicationId || result?.result_status !== "cancelled"
    || !isUpdatedAt(result?.result_updated_at)) return communityFailure("update-failed", fields);
  const path = `/staff/community/applications/${fields.applicationId}`;
  for (const route of [path, "/staff", "/staff/community", "/staff/community/applications", "/staff/calendar", "/calendar",
    "/user", "/user/applications", `/user/applications/${fields.applicationId}`]) revalidatePath(route);
  redirect(`${path}?updated=cancelled`);
}
