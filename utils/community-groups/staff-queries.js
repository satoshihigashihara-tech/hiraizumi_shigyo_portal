import "server-only";

import { requireStaff } from "@/utils/auth/guards";
import { groupErrorCode, isUuid } from "@/utils/community-groups/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row?.[key] ?? null]));

export async function getStaffCommunityGroupReview(groupId) {
  const { supabase } = await requireStaff("/staff/community/groups");
  if (!isUuid(groupId)) return { error: "not-found", group: null };
  const { data, error } = await supabase.rpc("get_staff_group_review_context", { target_group_id: groupId });
  if (error) return { error: groupErrorCode(error) === "not-found" ? "not-found" : "load-failed", group: null };
  if (!data || data.id !== groupId) return { error: "load-failed", group: null };
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
  if (!data || data.id !== groupId) return { error: "load-failed", cancellation: null };
  return { error: null, cancellation: pick(data, ["id", "group_name", "status", "updated_at", "start_date", "end_date",
    "cancel_reason", "can_request", "can_confirm"]) };
}
