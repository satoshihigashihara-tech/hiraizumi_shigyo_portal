import "server-only";

import { requireActiveUser, requireStaff } from "@/utils/auth/guards";
import { isUuid, communityErrorCode, FIELD_NAMES } from "@/utils/community-applications/validation";

const START_PATH = "/user/applications/new/community-activity";
const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));
const roomResult = (data) => ({
  room_allocation: data.room_allocation ? pick(data.room_allocation,
    ["room_id", "room_name", "people_count", "start_date", "end_date", "released_from", "is_current"]) : null,
  stay: data.stay ? pick(data.stay, ["status", "checked_in_at", "checked_out_at"]) : null,
});

export async function getCommunityApplication(applicationId, mode = "detail") {
  const { supabase } = await requireActiveUser(START_PATH);
  if (!isUuid(applicationId) || !["detail", "edit", "confirm", "complete"].includes(mode)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_community_application", { target_application_id: applicationId });
  if (error) return { error: communityErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (!data || data.id !== applicationId || !data.fields) return { error: "load-failed", application: null };
  const application = pick(data, ["id", "status", "updated_at", "reserved_start_date", "reserved_end_date", "submitted_at", "last_submitted_at",
    "revision_due_at", "decision_reason", "approval_comment", "reception_number", "has_consent", "can_edit"]);
  Object.assign(application, roomResult(data));
  application.fields = pick(data.fields, Object.values(FIELD_NAMES));
  application.events = (Array.isArray(data.events) ? data.events : []).map((row) => pick(row, ["from_status", "to_status", "public_reason", "occurred_at"]));
  const months = (rows) => (Array.isArray(rows) ? rows : []).map((row) => pick(row, ["month", "usage_days", "daily_rate", "monthly_cap", "amount"]));
  application.estimated_months = months(data.estimated_months);
  application.charge = data.charge ? { ...pick(data.charge, ["total_amount", "payment_status", "payment_due_date"]), months: months(data.charge.months) } : null;
  if (mode === "complete" && (!data.submitted_at || !data.reception_number)) return { error: "not-submittable", application: null };
  if (["edit", "confirm"].includes(mode) && !data.can_edit) return { error: data.status === "revision_requested" ? "revision-expired" : "not-editable", application };
  if (mode === "confirm" && data.validation_error) return { error: communityErrorCode(data.validation_error), application };
  return { error: null, application };
}

export async function getCommunityApplications(page = 1) {
  const { supabase, user } = await requireActiveUser("/user/applications");
  if (!Number.isInteger(page) || page < 1 || page > 10000) return { error: "invalid-page", applications: [] };
  const columns = ["id", "status", "start_date", "end_date", "updated_at", "submitted_at", "last_submitted_at", "revision_due_at", "decision_reason"];
  const { data, error } = await supabase.from("applications").select(columns.join(",")).eq("user_id", user.id).eq("usage_type", "community_individual")
    .order("created_at", { ascending: false }).order("id", { ascending: false }).range((page - 1) * 50, page * 50 - 1);
  return error || !Array.isArray(data) ? { error: "load-failed", applications: [] } : { error: null, applications: data.map((row) => pick(row, columns)) };
}

// One read-only DB snapshot keeps the displayed room and parent version together.
// Room names/capacities are choices, not a promise of availability at save time.
export async function getStaffCommunityApplicationRoomContext(applicationId) {
  const { supabase } = await requireStaff("/staff/community/applications");
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_staff_community_application_room_context", { target_application_id: applicationId });
  if (error) return { error: communityErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (!data || data.id !== applicationId || !Array.isArray(data.rooms)) return { error: "load-failed", application: null };
  return { error: null, application: {
    ...pick(data, ["id", "status", "updated_at", "start_date", "end_date", "approval_comment"]),
    ...roomResult(data), rooms: data.rooms.map((room) => pick(room, ["id", "name", "capacity"])),
  } };
}
