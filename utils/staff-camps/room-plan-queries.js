import "server-only";
import { requireStaff } from "@/utils/auth/guards";
import { isRoomPlanId, roomPlanVersion } from "@/utils/staff-camps/room-plan-validation";

export async function getStaffCampRoomPlan(campId) {
  const { supabase } = await requireStaff("/staff/camps");
  if (!isRoomPlanId(campId)) return { error: "not-found", plan: null };
  campId = campId.toLowerCase();
  const { data, error } = await supabase.rpc("get_staff_camp_room_plan", { target_camp_id: campId });
  if (error || !data || data.camp_id !== campId || roomPlanVersion(data.roster_version) === null
    || roomPlanVersion(data.room_plan_version) === null
    || (data.saved_roster_version !== null && roomPlanVersion(data.saved_roster_version) === null)
    || (data.room_plan_committed_at !== null && (typeof data.room_plan_committed_at !== "string" || !Number.isFinite(Date.parse(data.room_plan_committed_at))))
    || !Array.isArray(data.eligible_users) || data.eligible_users.some((row) => !isRoomPlanId(row?.id)
      || (row.management_name !== null && typeof row.management_name !== "string")
      || (row.room_id !== null && !isRoomPlanId(row.room_id))
      || (row.assignment_version !== null && (roomPlanVersion(row.assignment_version) === null || roomPlanVersion(row.assignment_version) === "0")))
    || !Array.isArray(data.rooms) || data.rooms.some((row) => !isRoomPlanId(row?.id) || typeof row.name !== "string"
      || !Number.isSafeInteger(row.capacity) || row.capacity < 1)) return { error: "load-failed", plan: null };
  return { error: null, plan: {
    campId, rosterVersion: roomPlanVersion(data.roster_version), roomPlanVersion: roomPlanVersion(data.room_plan_version),
    savedRosterVersion: data.saved_roster_version === null ? null : roomPlanVersion(data.saved_roster_version),
    committedAt: data.room_plan_committed_at,
    complete: data.eligible_users.length > 0 && data.eligible_users.every((row) => row.room_id !== null && row.assignment_version !== null)
      && data.room_plan_committed_at !== null && roomPlanVersion(data.saved_roster_version) === roomPlanVersion(data.roster_version),
    users: data.eligible_users.map((row) => ({ id: row.id, managementName: row.management_name,
      roomId: row.room_id, assignmentVersion: row.assignment_version === null ? null : roomPlanVersion(row.assignment_version) })),
    rooms: data.rooms.map((row) => ({ id: row.id, name: row.name, capacity: row.capacity })),
  } };
}
