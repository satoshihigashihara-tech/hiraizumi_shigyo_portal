import "server-only";
import { requireStaff } from "@/utils/auth/guards";
import { isUuid, isUpdatedAt } from "@/utils/calendar/validation";
import { validLifecycleResult, pickLifecycle, lifecycleError } from "@/utils/staff-camps/lifecycle-validation";

export async function getStaffCampRosterLifecycle(campId, eligibleUserId) {
  const { supabase } = await requireStaff("/staff/camps");
  if (!isUuid(campId) || !isUuid(eligibleUserId)) return { error: "not-found", participant: null };
  const { data, error } = await supabase.rpc("get_staff_camp_roster_lifecycle", {
    target_camp_id: campId, target_eligible_user_id: eligibleUserId,
  });
  if (error) return { error: lifecycleError(error) === "save-failed" ? "load-failed" : lifecycleError(error), participant: null };
  if (!validLifecycleResult(data, campId, eligibleUserId)
    || !["can_withdraw", "can_reject", "requires_checkout_confirmation"].every((key) => typeof data[key] === "boolean")
    || (data.management_name !== null && typeof data.management_name !== "string")
    || (data.release_reason !== null && typeof data.release_reason !== "string")
    || (data.released_at !== null && !isUpdatedAt(data.released_at))) return { error: "load-failed", participant: null };
  return { error: null, participant: { ...pickLifecycle(data), management_name: data.management_name,
    released_at: data.released_at, release_reason: data.release_reason, can_withdraw: data.can_withdraw,
    can_reject: data.can_reject, requires_checkout_confirmation: data.requires_checkout_confirmation } };
}
