const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isRoomPlanId = (value) => typeof value === "string" && UUID.test(value);
// Preserve bigint versions as decimal strings across JSON and FormData.
export function roomPlanVersion(value) {
  if (typeof value === "number" && !Number.isSafeInteger(value)) return null;
  if (typeof value !== "string" && typeof value !== "number") return null;
  const text = String(value);
  return /^(0|[1-9][0-9]{0,18})$/.test(text) && BigInt(text) <= 9223372036854775807n ? text : null;
}
export function validateRoomPlan(formData) {
  const fields = Object.fromEntries(["campId", "rosterVersion", "roomPlanVersion", "assignments"].map((key) => {
    const value = formData.get(key);
    return [key, typeof value === "string" ? value : ""];
  }));
  if (!isRoomPlanId(fields.campId)) return { error: "not-found", fields };
  fields.campId = fields.campId.toLowerCase();
  if (roomPlanVersion(fields.rosterVersion) === null || roomPlanVersion(fields.roomPlanVersion) === null) return { error: "invalid-version", fields };
  if (fields.assignments.length > 4096) return { error: "invalid-assignments", fields: { ...fields, assignments: "" } };
  let assignments;
  try { assignments = JSON.parse(fields.assignments); } catch { return { error: "invalid-assignments", fields }; }
  if (!Array.isArray(assignments) || assignments.length < 1 || assignments.length > 15 || assignments.some((row) =>
    !row || typeof row !== "object" || Array.isArray(row) || Object.keys(row).length !== 2
    || !isRoomPlanId(row.eligible_user_id) || !isRoomPlanId(row.room_id))) return { error: "invalid-assignments", fields };
  assignments = assignments.map((row) => ({ eligible_user_id: row.eligible_user_id.toLowerCase(), room_id: row.room_id.toLowerCase() }));
  if (new Set(assignments.map((row) => row.eligible_user_id)).size !== assignments.length) return { error: "duplicate-assignment", fields };
  return { error: null, fields, assignments };
}
const ERRORS = new Set(["not-found", "eligible-roster-required", "invalid-version", "stale-update", "invalid-assignments",
  "duplicate-assignment", "invalid-roster", "room-not-confirmed", "room-capacity-full", "facility-capacity-full",
  "date-conflict", "calendar-inconsistent", "camp-started", "roster-lifecycle-required", "room-change-review-required"]);
export function roomPlanError(error) {
  if (error?.code === "42501") return "staff-required";
  if (error?.code === "40001") return "stale-update";
  return error?.code === "P0001" && ERRORS.has(error.message) ? error.message : "save-failed";
}
