"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/utils/auth/guards";
import { isRoomPlanId } from "@/utils/staff-camps/room-plan-validation";
import { isUpdatedAt } from "@/utils/application-operations/validation";
import { validateRoomChange, validateReview, campReviewError } from "@/utils/staff-camps/review-validation";

function refreshCamp(campId) {
  for (const path of [`/staff/camps/${campId}`, `/staff/camps/${campId}/room-plan`, `/staff/camps/${campId}/eligible-users`,
    "/staff", "/staff/calendar", "/calendar", "/user", "/user/applications", "/user/camp-room"]) revalidatePath(path);
  revalidatePath("/staff/camps/[campId]/applications/[applicationId]", "page");
  revalidatePath("/user/applications/[applicationId]", "page");
  revalidatePath("/user/applications/[applicationId]/confirm", "page");
}
export async function changeCampRoomsState(_previous, formData) {
  const { supabase } = await requireStaff("/staff/camps");
  const input = validateRoomChange(formData);
  if (input.error) return { error: input.error, fields: input.fields };
  const { fields, assignments, participants } = input;
  const { data, error } = await supabase.rpc("change_camp_rooms_and_request_revisions", {
    target_camp_id: fields.campId, expected_roster_version: fields.rosterVersion,
    expected_room_plan_version: fields.roomPlanVersion, submitted_assignments: assignments,
    expected_participants: participants, change_reason: fields.reason, confirmed: true,
  });
  if (error) return { error: campReviewError(error), fields };
  if (!data || data.camp_id !== fields.campId || data.roster_version !== fields.rosterVersion || typeof data.changed !== "boolean"
    || data.room_plan_version !== String(BigInt(fields.roomPlanVersion) + (data.changed ? 1n : 0n))
    || !Array.isArray(data.changed_ids) || !data.changed_ids.every(isRoomPlanId)
    || !Array.isArray(data.revised_ids) || !data.revised_ids.every(isRoomPlanId)) return { error: "save-failed", fields };
  refreshCamp(fields.campId);
  return { error: null, saved: true, changed: data.changed, revisedCount: data.revised_ids.length };
}
export async function reviewCampRosterState(_previous, formData) {
  const { supabase } = await requireStaff("/staff");
  const { error: invalid, fields } = validateReview(formData);
  if (invalid) return { error: invalid, fields };
  const { data, error } = await supabase.rpc("review_camp_roster_application", {
    target_camp_id: fields.campId, target_application_id: fields.applicationId,
    expected_updated_at: fields.updatedAt, expected_room_plan_version: fields.roomPlanVersion,
    expected_assignment_version: fields.assignmentVersion, expected_submitted_version_id: fields.submittedVersionId,
    review_action: fields.reviewAction, public_reason: fields.reason || null,
  });
  if (error) return { error: campReviewError(error), fields };
  const expectedStatus = { start_review: "under_review", request_revision: "revision_requested", approve: "approved" }[fields.reviewAction];
  if (!data || data.camp_id !== fields.campId || data.application_id !== fields.applicationId
    || data.status !== expectedStatus || !isUpdatedAt(data.updated_at)) return { error: "save-failed", fields };
  refreshCamp(fields.campId);
  return { error: null, saved: true, status: data.status };
}
