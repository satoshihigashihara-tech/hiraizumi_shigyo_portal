import { isRoomPlanId, roomPlanVersion, validateRoomPlan } from "./room-plan-validation";
import { isUpdatedAt } from "@/utils/application-operations/validation";

export const reviewActions = ["start_review", "request_revision", "approve"];
export const textFields = (form, keys) => Object.fromEntries(keys.map((key) => [key,
  typeof form.get(key) === "string" ? form.get(key).trim() : ""]));
export function validateParticipants(value) {
  if (typeof value !== "string" || value.length > 16000) return null;
  let rows;
  try { rows = JSON.parse(value); } catch { return null; }
  const keys = ["eligible_user_id", "updated_at", "application_id", "application_updated_at"];
  if (!Array.isArray(rows) || rows.length < 1 || rows.length > 15 || rows.some((r) => !r || Array.isArray(r)
    || Object.keys(r).length !== 4 || !keys.every((key) => Object.hasOwn(r, key))
    || !isRoomPlanId(r.eligible_user_id) || !isUpdatedAt(r.updated_at)
    || (r.application_id === null ? r.application_updated_at !== null
      : !isRoomPlanId(r.application_id) || !isUpdatedAt(r.application_updated_at)))) return null;
  rows = rows.map((r) => ({ ...r, eligible_user_id: r.eligible_user_id.toLowerCase(), application_id: r.application_id?.toLowerCase() ?? null }));
  return new Set(rows.map((r) => r.eligible_user_id)).size === rows.length ? rows : null;
}
export function validateRoomChange(form) {
  const base = validateRoomPlan(form);
  const fields = { ...base.fields, ...textFields(form, ["participants", "reason", "confirmed"]) };
  if (base.error) return { error: base.error, fields };
  const participants = validateParticipants(fields.participants);
  if (!participants || participants.length !== base.assignments.length
    || participants.some((r) => !base.assignments.some((x) => x.eligible_user_id === r.eligible_user_id))) return { error: "invalid-expectations", fields };
  if (!fields.reason) return { error: "reason-required", fields };
  if (Array.from(fields.reason).length > 2000) return { error: "reason-too-long", fields };
  if (fields.confirmed !== "yes") return { error: "confirmation-required", fields };
  return { ...base, fields, participants };
}
export function validateReview(form) {
  const fields = textFields(form, ["campId", "applicationId", "updatedAt", "roomPlanVersion", "assignmentVersion", "submittedVersionId", "reviewAction", "reason"]);
  let error = null;
  if (![fields.campId, fields.applicationId, fields.submittedVersionId].every(isRoomPlanId)) error = "not-found";
  else if (!isUpdatedAt(fields.updatedAt) || roomPlanVersion(fields.roomPlanVersion) === null
    || roomPlanVersion(fields.assignmentVersion) === null || fields.assignmentVersion === "0") error = "invalid-version";
  else if (!reviewActions.includes(fields.reviewAction)) error = "invalid-action";
  else if (fields.reviewAction === "request_revision" && !fields.reason) error = "reason-required";
  else if (Array.from(fields.reason).length > 2000) error = "reason-too-long";
  return { error, fields };
}
const known = new Set(["not-found", "eligible-roster-required", "invalid-version", "stale-update", "invalid-expectations",
  "invalid-action", "invalid-status", "invalid-stay", "invalid-allocation", "invalid-assignments", "invalid-roster",
  "duplicate-assignment", "room-not-confirmed", "room-capacity-full", "facility-capacity-full", "camp-started",
  "date-conflict", "calendar-inconsistent", "application-inconsistent", "roster-lifecycle-required", "submitted-pdf-inconsistent", "deadline-passed",
  "pdf-assignment-unavailable", "pdf-room-not-printable", "pdf-calendar-unavailable", "reason-required", "reason-too-long", "confirmation-required"]);
export function campReviewError(error) {
  if (error?.code === "42501") return "staff-required";
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  return error?.code === "P0001" && known.has(error.message) ? error.message : "save-failed";
}
