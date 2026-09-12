"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/utils/auth/guards";
import { validateRoomPlan, roomPlanVersion, roomPlanError } from "@/utils/staff-camps/room-plan-validation";

export async function saveCampRoomPlanState(_previousState, formData) {
  const { supabase } = await requireStaff("/staff/camps");
  const input = validateRoomPlan(formData);
  if (input.error) return { error: input.error, fields: input.fields };
  const { fields, assignments } = input;
  const { data, error } = await supabase.rpc("save_camp_room_plan", {
    target_camp_id: fields.campId,
    expected_roster_version: fields.rosterVersion,
    expected_room_plan_version: fields.roomPlanVersion,
    submitted_assignments: assignments,
  });
  if (error) return { error: roomPlanError(error), fields };
  if (!data || data.camp_id !== fields.campId || roomPlanVersion(data.roster_version) !== fields.rosterVersion
    || roomPlanVersion(data.saved_roster_version) !== fields.rosterVersion
    || roomPlanVersion(data.room_plan_version) !== String(BigInt(fields.roomPlanVersion) + 1n)) {
    return { error: "save-failed", fields };
  }
  revalidatePath(`/staff/camps/${fields.campId}`);
  revalidatePath(`/staff/camps/${fields.campId}/eligible-users`);
  revalidatePath("/staff/calendar");
  revalidatePath("/calendar");
  return { error: null, fields: { ...fields, roomPlanVersion: String(data.room_plan_version) }, saved: true };
}
