"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { getText } from "@/utils/calendar/validation";
import { isUuid, isUpdatedAt, validatePayment, paymentFailure } from "@/utils/application-operations/validation";

export async function updateApplicationPayment(formData) {
  const { supabase } = await requireStaff("/staff");
  const fields = Object.fromEntries(["applicationId", "updatedAt", "paymentStatus", "paymentDueDate", "reason"]
    .map((name) => [name, getText(formData, name)]));
  const invalid = validatePayment(fields);
  if (invalid) return paymentFailure(invalid, fields);
  const { data, error } = await supabase.rpc("update_application_payment", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    target_payment_status: fields.paymentStatus, target_payment_due_date: fields.paymentDueDate || null,
    change_reason: fields.reason || null,
  });
  if (error) return paymentFailure(error, fields);
  const result = Array.isArray(data) && data.length === 1 ? data[0] : null;
  if (result?.result_id !== fields.applicationId || !isUpdatedAt(result.result_updated_at)
    || !["camp", "community_individual"].includes(result.result_usage_type)
    || (result.result_usage_type === "camp" ? !isUuid(result.result_camp_id) : result.result_camp_id !== null)) {
    return paymentFailure("update-failed", fields);
  }
  // Determine the canonical URL from the DB result, never a client-provided camp ID.
  const base = result.result_usage_type === "camp" ? `/staff/camps/${result.result_camp_id}` : "/staff/community";
  const path = `${base}/applications/${fields.applicationId}`;
  for (const route of [path, base, `${base}/applications`, "/staff", "/user", "/user/applications",
    ...["", "/edit", "/confirm", "/complete"].map((suffix) => `/user/applications/${fields.applicationId}${suffix}`)]) {
    revalidatePath(route);
  }
  redirect(`${path}?updated=payment-updated`);
}
