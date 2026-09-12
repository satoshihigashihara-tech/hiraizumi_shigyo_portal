import "server-only";
import { requireStaff } from "@/utils/auth/guards";
import { isRoomPlanId, roomPlanVersion } from "@/utils/staff-camps/room-plan-validation";
import { isUpdatedAt, APPLICATION_STATUSES } from "@/utils/application-operations/validation";
import { validateParticipants } from "@/utils/staff-camps/review-validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));
export async function getStaffCampRoomChange(campId) {
  const { supabase } = await requireStaff("/staff/camps");
  if (!isRoomPlanId(campId)) return { error: "not-found", context: null };
  const { data: d, error } = await supabase.rpc("get_staff_camp_room_change_context", { target_camp_id: campId });
  const expectations = Array.isArray(d?.participants) && d.participants.every((r) => r && typeof r === "object") ? d.participants.map((r) => pick(r, ["eligible_user_id", "updated_at", "application_id", "application_updated_at"])) : null;
  if (error || d?.camp_id !== campId || roomPlanVersion(d.roster_version) === null || roomPlanVersion(d.room_plan_version) === null
    || typeof d.can_change !== "boolean" || (d.can_change && !isUpdatedAt(d.proposed_revision_due_at)) || !Array.isArray(d.participants)
    || (d.participants.length > 0 && !validateParticipants(JSON.stringify(expectations)))
    || d.participants.some((r) => !r || (r.application_status !== null && !APPLICATION_STATUSES.includes(r.application_status))
      || (r.application_status === "revision_requested" && !isUpdatedAt(r.revision_due_at)))
    || !Array.isArray(d.eligible_users) || d.eligible_users.length !== d.participants.length
    || d.eligible_users.some((r) => !r || !isRoomPlanId(r.id) || !d.participants.some((p) => p.eligible_user_id === r.id)
      || (r.management_name !== null && typeof r.management_name !== "string") || (r.room_id !== null && !isRoomPlanId(r.room_id)))
    || !Array.isArray(d.rooms) || d.rooms.some((r) => !r || !isRoomPlanId(r.id) || typeof r.name !== "string" || !Number.isSafeInteger(r.capacity) || r.capacity < 1)) {
    return { error: "load-failed", context: null };
  }
  return { error: null, context: { campId, rosterVersion: String(d.roster_version), roomPlanVersion: String(d.room_plan_version),
    canChange: d.can_change, proposedRevisionDueAt: d.proposed_revision_due_at, expectations,
    users: d.eligible_users.map((r) => ({ id: r.id, name: r.management_name, roomId: r.room_id,
      revisionDueAt: d.participants.find((p) => p.eligible_user_id === r.id).revision_due_at,
      status: d.participants.find((p) => p.eligible_user_id === r.id).application_status })),
    rooms: d.rooms.map((r) => pick(r, ["id", "name", "capacity"])) } };
}
export async function getStaffCampRosterReview(campId, applicationId) {
  const { supabase } = await requireStaff("/staff");
  if (![campId, applicationId].every(isRoomPlanId)) return { error: "not-found", review: null };
  const { data: d, error } = await supabase.rpc("get_staff_camp_roster_application_review", { target_camp_id: campId, target_application_id: applicationId });
  if (error || d?.camp_id !== campId || d?.application_id !== applicationId || !isUpdatedAt(d.updated_at)
    || !APPLICATION_STATUSES.includes(d.status) || roomPlanVersion(d.room_plan_version) === null
    || (d.assignment_version !== null && roomPlanVersion(d.assignment_version) === null)
    || (d.submitted_version_id !== null && !isRoomPlanId(d.submitted_version_id)) || typeof d.can_review !== "boolean"
    || (d.room_name !== null && typeof d.room_name !== "string") || typeof d.previously_approved !== "boolean" || !Array.isArray(d.versions)
    || d.versions.some((v) => !v || !isRoomPlanId(v.id) || roomPlanVersion(v.version_no) === null || !isUpdatedAt(v.submitted_at))) return { error: "load-failed", review: null };
  const snapshotFields = ["user_name", "user_address", "user_phone", "emergency_name", "emergency_address", "emergency_phone", "usage_place", "purpose", "special_notes", "start_date", "end_date"];
  if (d.snapshot !== null && (typeof d.snapshot !== "object" || snapshotFields.some((k) => d.snapshot[k] !== null && typeof d.snapshot[k] !== "string"))) return { error: "load-failed", review: null };
  const l = d.lifecycle;
  if (!l || l.camp_id !== campId || !isRoomPlanId(l.eligible_user_id) || !isUpdatedAt(l.updated_at)
    || l.application_id !== applicationId || l.application_updated_at !== d.updated_at
    || roomPlanVersion(l.roster_version) === null || l.room_plan_version !== d.room_plan_version || typeof l.can_reject !== "boolean") return { error: "load-failed", review: null };
  return { error: null, review: { ...pick(d, ["camp_id", "application_id", "updated_at", "status", "room_plan_version", "assignment_version", "submitted_version_id", "can_review", "previously_approved", "room_name"]),
    snapshot: d.snapshot ? pick(d.snapshot, snapshotFields) : null,
    versions: d.versions.map((v) => pick(v, ["id", "version_no", "submitted_at"])),
    lifecycle: pick(l, ["camp_id", "eligible_user_id", "updated_at", "roster_version", "room_plan_version", "application_id", "application_updated_at", "can_reject"]) } };
}
