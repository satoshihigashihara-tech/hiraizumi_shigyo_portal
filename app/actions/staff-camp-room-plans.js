"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/utils/auth/guards";
import { validateRoomPlan, roomPlanVersion, roomPlanError } from "@/utils/staff-camps/room-plan-validation";

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

export async function generateStaffCampRoomPlanPdfState(_previousState, formData) {
  const { supabase } = await requireStaff('/staff/camps');
  const campId = String(formData.get('campId') ?? '').toLowerCase();
  const rosterVersion = roomPlanVersion(formData.get('rosterVersion'));
  const rosterLabelVersion = roomPlanVersion(formData.get('rosterLabelVersion'));
  const planVersion = roomPlanVersion(formData.get('roomPlanVersion'));
  if (!ID.test(campId) || rosterVersion === null || rosterLabelVersion === null || planVersion === null) return { error: 'invalid-request' };
  const { data, error } = await supabase.rpc('begin_staff_camp_room_plan_pdf', {
    target_camp_id: campId, expected_roster_version: rosterVersion,
    expected_roster_label_version: rosterLabelVersion, expected_room_plan_version: planVersion,
    request_key_value: crypto.randomUUID(),
  });
  if (error || !ID.test(data ?? '')) {
    const code = ['stale-update', 'room-plan-incomplete', 'calendar-inconsistent', 'pdf-prerequisites-unavailable'].includes(error?.message) ? error.message : 'save-failed';
    return { error: code };
  }
  revalidatePath(`/staff/camps/${campId}/room-plan`);
  return { error: null, requested: true };
}
