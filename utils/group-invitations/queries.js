import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";
import { inviteErrorCode, isUuid, normalizeInvite } from "@/utils/group-invitations/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));

export async function getCommunityGroupInvite(inviteValue, inviteKind) {
  const { supabase } = await requireActiveUser("/invite");
  const normalized = normalizeInvite(inviteValue, inviteKind);
  if (!normalized) return { error: "invalid-invite", invite: null };
  const { data, error } = await supabase.rpc("get_community_group_invite", {
    invite_value: normalized, invite_kind: inviteKind,
  });
  if (error) {
    const code = inviteErrorCode(error);
    return { error: ["invalid-invite", "invite-expired"].includes(code) ? code : "load-failed", invite: null };
  }
  if (!data || !isUuid(data.group_id)) return { error: "load-failed", invite: null };
  return { error: null, invite: pick(data, ["group_id", "group_name", "start_date", "end_date", "purpose",
    "local_activity", "planned_participants", "participant_due_at", "joined_participants",
    "already_joined_application_id", "can_join"]) };
}

export async function getCommunityGroupParticipants(groupId) {
  const { supabase } = await requireActiveUser("/user/groups");
  if (!isUuid(groupId)) return { error: "not-found", group: null };
  const { data, error } = await supabase.rpc("get_community_group_participants", { target_group_id: groupId });
  if (error) return { error: inviteErrorCode(error) === "not-found" ? "not-found" : "load-failed", group: null };
  if (!data || data.group_id !== groupId || !Array.isArray(data.participants)) return { error: "load-failed", group: null };
  const group = pick(data, ["group_id", "group_name", "status", "updated_at", "planned_participants", "participant_due_at"]);
  group.participants = data.participants.map((row) => pick(row,
    ["application_id", "name", "application_status", "is_representative", "joined_at"]));
  return { error: null, group };
}
