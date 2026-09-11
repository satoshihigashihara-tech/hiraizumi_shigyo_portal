import "server-only";

import { requireActiveUser, requireStaff } from "@/utils/auth/guards";
import { isUuid, isUpdatedAt, isPaymentOverdue, paymentErrorCode } from "@/utils/application-operations/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));
async function readPayment(supabase, applicationId) {
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_application_payment", { target_application_id: applicationId });
  if (error) return { error: paymentErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (data?.id !== applicationId || !isUpdatedAt(data.updated_at)
    || !["camp", "community_individual"].includes(data.usage_type)) return { error: "load-failed", application: null };
  const application = pick(data, ["id", "usage_type", "camp_id", "status", "updated_at"]);
  application.charge = data.charge ? {
    ...pick(data.charge, ["total_amount", "payment_status", "payment_due_date", "paid_at"]),
    is_overdue: isPaymentOverdue(data.charge),
    months: (Array.isArray(data.charge.months) ? data.charge.months : [])
      .map((row) => pick(row, ["month", "usage_days", "daily_rate", "monthly_cap", "amount"])),
  } : null;
  return { error: null, application };
}

export async function getApplicationPayment(applicationId) {
  const { supabase } = await requireActiveUser("/user/applications");
  return readPayment(supabase, applicationId);
}

export async function getStaffApplicationPayment(applicationId) {
  const { supabase } = await requireStaff("/staff");
  return readPayment(supabase, applicationId);
}
