import { isUuid, isUpdatedAt, isDate } from "@/utils/calendar/validation";
import { roomPlanVersion } from "@/utils/staff-camps/room-plan-validation";

export function validateLifecycle(formData) {
  const fields = Object.fromEntries(["campId", "eligibleUserId", "updatedAt", "rosterVersion", "roomPlanVersion",
    "applicationId", "applicationUpdatedAt", "endAction", "reason", "confirmed", "checkoutConfirmed"].map((key) => {
    const value = formData.get(key);
    return [key, typeof value === "string" ? value.trim() : ""];
  }));
  let error = null;
  if (!isUuid(fields.campId) || !isUuid(fields.eligibleUserId)) error = "not-found";
  else if (!isUpdatedAt(fields.updatedAt) || roomPlanVersion(fields.rosterVersion) === null
    || roomPlanVersion(fields.roomPlanVersion) === null
    || (fields.applicationId ? !isUuid(fields.applicationId) || !isUpdatedAt(fields.applicationUpdatedAt) : fields.applicationUpdatedAt !== "")) error = "invalid-version";
  else if (!["withdraw", "reject"].includes(fields.endAction)) error = "invalid-action";
  else if (!fields.reason) error = "reason-required";
  else if (Array.from(fields.reason).length > 2000) error = "reason-too-long";
  else if (fields.confirmed !== "yes") error = "confirmation-required";
  return { fields, error };
}
const ERRORS = new Set(["not-found", "eligible-roster-required", "invalid-version", "stale-update", "invalid-action",
  "reason-required", "reason-too-long", "confirmation-required", "checkout-confirmation-required", "invalid-status",
  "invalid-stay", "invalid-allocation", "calendar-inconsistent"]);
export function lifecycleError(error) {
  if (error?.code === "42501") return "staff-required";
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  return error?.code === "P0001" && ERRORS.has(error.message) ? error.message : "save-failed";
}
export function validLifecycleResult(data, campId, eligibleUserId) {
  return data?.camp_id === campId && data?.eligible_user_id === eligibleUserId && isUpdatedAt(data.updated_at)
    && roomPlanVersion(data.roster_version) !== null && roomPlanVersion(data.room_plan_version) !== null
    && ["participating", "released"].includes(data.participation_status)
    && (data.disabled_at === null || isUpdatedAt(data.disabled_at))
    && (data.application_id === null ? data.application_updated_at === null && data.application_status === null
      : isUuid(data.application_id) && isUpdatedAt(data.application_updated_at)
        && ["draft", "submitted", "under_review", "revision_requested", "approved", "rejected", "cancelled"].includes(data.application_status))
    && (data.stay_status === null || ["before_move_in", "staying", "moved_out"].includes(data.stay_status))
    && (data.released_from === null || isDate(data.released_from));
}
export function pickLifecycle(data) {
  return Object.fromEntries(["camp_id", "eligible_user_id", "updated_at", "roster_version", "room_plan_version",
    "disabled_at", "participation_status", "application_id", "application_updated_at", "application_status", "stay_status", "released_from"]
    .map((key) => [key, data[key]]));
}
