import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";
import { GROUP_FIELD_NAMES, groupErrorCode, isUuid } from "@/utils/community-groups/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));

export async function getCommunityGroup(groupId, mode = "detail") {
  const { supabase } = await requireActiveUser("/user/groups");
  if (!isUuid(groupId) || !["detail", "edit", "confirm", "complete"].includes(mode)) {
    return { error: "not-found", group: null };
  }
  const { data, error } = await supabase.rpc("get_community_group", { target_group_id: groupId });
  if (error) return { error: groupErrorCode(error) === "not-found" ? "not-found" : "load-failed", group: null };
  if (!data || data.id !== groupId || !data.fields) return { error: "load-failed", group: null };
  const group = pick(data, ["id", "status", "updated_at", "submitted_at", "participant_due_at", "reception_number"]);
  group.fields = pick(data.fields, Object.values(GROUP_FIELD_NAMES));
  group.events = (Array.isArray(data.events) ? data.events : [])
    .map((row) => pick(row, ["from_status", "to_status", "public_reason", "occurred_at"]));
  if (["edit", "confirm"].includes(mode) && group.status !== "draft") return { error: "not-editable", group };
  if (mode === "complete" && (!group.submitted_at || !group.reception_number)) return { error: "not-submittable", group: null };
  return { error: null, group };
}

export async function getCommunityGroups(page = 1) {
  const { supabase, user } = await requireActiveUser("/user/groups");
  if (!Number.isInteger(page) || page < 1 || page > 10000) return { error: "invalid-page", groups: [] };
  const columns = ["id", "group_name", "status", "start_date", "end_date", "planned_participants",
    "updated_at", "submitted_at", "participant_due_at"];
  const { data, error } = await supabase.from("group_applications").select(columns.join(","))
    .eq("representative_user_id", user.id).order("created_at", { ascending: false })
    .order("id", { ascending: false }).range((page - 1) * 50, page * 50 - 1);
  return error || !Array.isArray(data)
    ? { error: "load-failed", groups: [] }
    : { error: null, groups: data.map((row) => pick(row, columns)) };
}
