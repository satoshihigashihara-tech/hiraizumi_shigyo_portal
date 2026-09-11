import "server-only";

import {
  isPaymentOverdue,
  isUpdatedAt,
  isUuid,
  paymentErrorCode,
  stayErrorCode,
} from "@/utils/application-operations/validation";

export {
  APPLICATION_STATUSES,
  STAFF_SEARCH_PAYMENT_STATUSES,
  STAFF_SEARCH_STAY_STATUSES,
  STAFF_SEARCH_USAGE_TYPES,
  isUpdatedAt,
  isUuid,
  normalizeStaffApplicationSearch,
  noteErrorCode,
  staffSearchErrorCode,
} from "@/utils/application-operations/validation";

const pick = (row, keys) =>
  Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));

export async function readApplicationPayment(supabase, applicationId) {
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_application_payment", {
    target_application_id: applicationId,
  });
  if (error) {
    return {
      error: paymentErrorCode(error) === "not-found" ? "not-found" : "load-failed",
      application: null,
    };
  }
  if (
    data?.id !== applicationId ||
    !isUpdatedAt(data.updated_at) ||
    !["camp", "community_individual"].includes(data.usage_type)
  ) {
    return { error: "load-failed", application: null };
  }
  const application = pick(data, [
    "id", "usage_type", "camp_id", "original_application_id", "status", "updated_at",
  ]);
  application.charge = data.charge
    ? {
        ...pick(data.charge, ["total_amount", "payment_status", "payment_due_date", "paid_at"]),
        is_overdue: isPaymentOverdue(data.charge),
        months: (Array.isArray(data.charge.months) ? data.charge.months : []).map(
          (row) => pick(row, ["month", "usage_days", "daily_rate", "monthly_cap", "amount"]),
        ),
      }
    : null;
  return { error: null, application };
}

export async function readApplicationStay(supabase, applicationId) {
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_application_stay", {
    target_application_id: applicationId,
  });
  if (error) {
    return {
      error: stayErrorCode(error) === "not-found" ? "not-found" : "load-failed",
      application: null,
    };
  }
  if (
    data?.id !== applicationId ||
    !isUpdatedAt(data.updated_at) ||
    !["camp", "community_individual"].includes(data.usage_type)
  ) {
    return { error: "load-failed", application: null };
  }
  return {
    error: null,
    application: {
      ...pick(data, [
        "id", "usage_type", "camp_id", "original_application_id", "status", "updated_at", "start_date", "end_date",
      ]),
      stay: data.stay
        ? pick(data.stay, ["status", "checked_in_at", "checked_out_at"])
        : null,
      room_allocation: data.room_allocation
        ? pick(data.room_allocation, [
            "room_id", "room_name", "people_count", "start_date", "end_date", "released_from", "is_current",
          ])
        : null,
    },
  };
}
