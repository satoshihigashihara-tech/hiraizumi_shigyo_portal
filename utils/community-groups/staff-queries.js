import "server-only";

import { requireStaff } from "@/utils/auth/guards";
import { groupErrorCode, isUpdatedAt, isUuid } from "@/utils/community-groups/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row?.[key] ?? null]));
const GROUP_STATUSES = ["draft", "collecting", "under_review", "revision_requested", "approved", "rejected", "cancellation_requested", "cancelled"];
const APPLICATION_STATUSES = ["draft", "submitted", "under_review", "revision_requested", "approved", "rejected", "cancellation_requested", "cancelled"];
const date = (value) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
const nullableDate = (value) => value === null || date(value);
const text = (value) => value === null || typeof value === "string";

export async function getStaffCommunityGroups(searchParams = {}) {
  const { supabase } = await requireStaff("/staff/community/groups");
  const q = typeof searchParams.q === "string" ? searchParams.q.trim() : "";
  const status = typeof searchParams.status === "string" ? searchParams.status : "";
  const pageValue = typeof searchParams.page === "string" ? searchParams.page : "1";
  const page = /^\d+$/.test(pageValue) ? Number(pageValue) : 0;
  const filters = { q, status, page: page || 1 };
  if (Array.from(q).length > 100) return { error: "invalid-query", filters, groups: [], pagination: { page: filters.page, totalCount: 0, hasNext: false } };
  if (status && !GROUP_STATUSES.includes(status)) return { error: "invalid-status", filters, groups: [], pagination: { page: filters.page, totalCount: 0, hasNext: false } };
  if (page < 1 || page > 10000) return { error: "invalid-page", filters, groups: [], pagination: { page: filters.page, totalCount: 0, hasNext: false } };

  const columns = ["id", "group_name", "status", "start_date", "end_date", "planned_participants", "purpose_reviewed_at", "updated_at"];
  let query = supabase.from("group_applications").select(columns.join(","), { count: "exact" })
    .order("created_at", { ascending: false }).order("id", { ascending: false });
  if (q) query = query.ilike("group_name", `%${q.replace(/[\\%_]/g, "\\$&")}%`);
  if (status) query = query.eq("status", status);
  const { data, error, count } = await query.range((page - 1) * 50, page * 50 - 1);
  const valid = Array.isArray(data) && data.every((row) => row && isUuid(row.id)
    && text(row.group_name) && GROUP_STATUSES.includes(row.status)
    && nullableDate(row.start_date) && nullableDate(row.end_date)
    && (row.planned_participants === null || (Number.isInteger(row.planned_participants)
      && row.planned_participants >= 0 && row.planned_participants <= 15))
    && (row.purpose_reviewed_at === null || isUpdatedAt(row.purpose_reviewed_at))
    && isUpdatedAt(row.updated_at));
  if (error || !valid || !Number.isInteger(count) || count < 0) {
    return { error: "load-failed", filters, groups: [], pagination: { page, totalCount: 0, hasNext: false } };
  }
  return { error: null, filters, groups: data.map((row) => pick(row, columns)),
    pagination: { page, totalCount: count, hasNext: page * 50 < count } };
}

export async function getStaffCommunityGroupReview(groupId) {
  const { supabase } = await requireStaff("/staff/community/groups");
  if (!isUuid(groupId)) return { error: "not-found", group: null };
  const { data, error } = await supabase.rpc("get_staff_group_review_context", { target_group_id: groupId });
  if (error) return { error: groupErrorCode(error) === "not-found" ? "not-found" : "load-failed", group: null };
  if (!data || data.id !== groupId || !GROUP_STATUSES.includes(data.status) || !isUpdatedAt(data.updated_at)
    || !date(data.start_date) || !date(data.end_date) || !text(data.group_name) || !text(data.purpose)
    || !text(data.local_activity) || !Number.isInteger(data.planned_participants)
    || data.planned_participants < 0 || data.planned_participants > 15
    || (data.purpose_reviewed_at !== null && !isUpdatedAt(data.purpose_reviewed_at))
    || !Array.isArray(data.participants) || !Array.isArray(data.allocations) || !Array.isArray(data.rooms)
    || !data.participants.every((row) => row && isUuid(row.application_id) && text(row.name)
      && APPLICATION_STATUSES.includes(row.status) && isUpdatedAt(row.updated_at))
    || !data.allocations.every((row) => row && isUuid(row.room_id) && typeof row.room_name === "string"
      && Number.isInteger(row.people_count) && row.people_count >= 1 && row.people_count <= 3
      && (row.released_from === null || date(row.released_from)))
    || !data.rooms.every((row) => row && isUuid(row.id) && typeof row.name === "string"
      && Number.isInteger(row.capacity) && row.capacity >= 1 && row.capacity <= 3)) {
    return { error: "load-failed", group: null };
  }
  return { error: null, group: { ...pick(data, ["id", "group_name", "status", "updated_at", "start_date", "end_date",
    "purpose", "local_activity", "planned_participants", "purpose_reviewed_at"]),
    participants: (Array.isArray(data.participants) ? data.participants : []).map((row) => pick(row,
      ["application_id", "name", "status", "updated_at"])),
    allocations: (Array.isArray(data.allocations) ? data.allocations : []).map((row) => pick(row,
      ["room_id", "room_name", "people_count", "released_from"])),
    rooms: (Array.isArray(data.rooms) ? data.rooms : []).map((row) => pick(row, ["id", "name", "capacity"])) } };
}

export async function getStaffCommunityGroupCancellation(groupId) {
  const { supabase } = await requireStaff("/staff/community/groups");
  if (!isUuid(groupId)) return { error: "not-found", cancellation: null };
  const { data, error } = await supabase.rpc("get_community_group_cancellation", { target_group_id: groupId });
  if (error) return { error: groupErrorCode(error) === "not-found" ? "not-found" : "load-failed", cancellation: null };
  if (!data || data.id !== groupId || !GROUP_STATUSES.includes(data.status) || !isUpdatedAt(data.updated_at)
    || !nullableDate(data.start_date) || !nullableDate(data.end_date) || !text(data.group_name)
    || !text(data.cancel_reason) || typeof data.can_request !== "boolean" || typeof data.can_confirm !== "boolean") {
    return { error: "load-failed", cancellation: null };
  }
  return { error: null, cancellation: pick(data, ["id", "group_name", "status", "updated_at", "start_date", "end_date",
    "cancel_reason", "can_request", "can_confirm"]) };
}
