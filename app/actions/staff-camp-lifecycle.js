"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/utils/auth/guards";
import { validateLifecycle, lifecycleError, validLifecycleResult, pickLifecycle } from "@/utils/staff-camps/lifecycle-validation";

export async function endCampRosterParticipationState(_previousState, formData) {
  const { supabase } = await requireStaff("/staff/camps");
  const { fields, error: invalid } = validateLifecycle(formData);
  if (invalid) return { error: invalid, fields };
  const { data, error } = await supabase.rpc("end_camp_roster_participation", {
    target_camp_id: fields.campId, target_eligible_user_id: fields.eligibleUserId,
    expected_updated_at: fields.updatedAt, expected_roster_version: fields.rosterVersion,
    expected_room_plan_version: fields.roomPlanVersion, expected_application_id: fields.applicationId || null,
    expected_application_updated_at: fields.applicationUpdatedAt || null, end_action: fields.endAction,
    change_reason: fields.reason, confirmed: true, checkout_confirmed: fields.checkoutConfirmed === "yes",
  });
  if (error) return { error: lifecycleError(error), fields };
  if (!validLifecycleResult(data, fields.campId, fields.eligibleUserId) || data.participation_status !== "released"
    || data.application_id !== (fields.applicationId || null)
    || data.roster_version !== String(BigInt(fields.rosterVersion) + 1n)
    || data.room_plan_version !== String(BigInt(fields.roomPlanVersion) + 1n)
    || (fields.endAction === "withdraw" ? data.disabled_at === null : data.disabled_at !== null || data.application_status !== "rejected")) {
    return { error: "save-failed", fields };
  }
  const base = `/staff/camps/${data.camp_id}`;
  for (const route of ["/staff", "/staff/camps", base, `${base}/eligible-users`, `${base}/room-plan`, `${base}/applications`,
    "/staff/calendar", "/calendar", "/user", "/user/camps", "/user/camp-room", "/user/applications"]) revalidatePath(route);
  if (data.application_id) {
    revalidatePath(`${base}/applications/${data.application_id}`);
    for (const suffix of ["", "/edit", "/confirm", "/complete"]) revalidatePath(`/user/applications/${data.application_id}${suffix}`);
  }
  return { error: null, saved: true, result: pickLifecycle(data) };
}
