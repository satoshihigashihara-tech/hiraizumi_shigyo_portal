"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { getText, isUuid, isUpdatedAt, periodError, reasonError, calendarFailure } from "@/utils/calendar/validation";

const LIST_PATH = "/staff/calendar/blocked-periods";

async function runBlockedPeriodAction(formData, operation) {
  const { supabase } = await requireStaff(LIST_PATH);
  const fields = Object.fromEntries([
    "blockedPeriodId", "startDate", "endDate", "internalReason", "updatedAt", "reason", "confirmed",
  ].map((key) => [key, getText(formData, key)]));
  const editing = operation !== "create";
  if (editing && !isUuid(fields.blockedPeriodId)) return calendarFailure("not-found", fields);
  if (editing && !isUpdatedAt(fields.updatedAt)) return calendarFailure("invalid-version", fields);
  const changeReasonError = reasonError(fields.reason, operation === "delete");
  if (changeReasonError) return calendarFailure(changeReasonError, fields, { reason: changeReasonError });
  if (operation === "delete" && fields.confirmed !== "true") {
    return calendarFailure("confirmation-required", fields, { confirmed: "confirmation-required" });
  }

  const input = {
    target_blocked_period_id: editing ? fields.blockedPeriodId : null,
    expected_updated_at: editing ? fields.updatedAt : null,
    change_reason: fields.reason || null,
  };
  let rpcName = "delete_staff_blocked_period";
  if (operation !== "delete") {
    const invalid = periodError(fields.startDate, fields.endDate) || reasonError(fields.internalReason);
    if (invalid) {
      const field = invalid === "invalid-period" ? "startDate" : "internalReason";
      return calendarFailure(invalid, fields, { [field]: invalid });
    }
    rpcName = "save_staff_blocked_period";
    input.blocked_start_date = fields.startDate;
    input.blocked_end_date = fields.endDate;
    input.internal_reason = fields.internalReason;
  }
  const { data, error } = await supabase.rpc(rpcName, input);
  if (error) return calendarFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  if (!isUuid(result?.result_id) || !isUpdatedAt(result?.result_updated_at)
    || (editing && result.result_id !== fields.blockedPeriodId)) {
    return calendarFailure("update-failed", fields);
  }
  revalidatePath("/calendar");
  revalidatePath("/staff/calendar");
  revalidatePath("/staff");
  revalidatePath(LIST_PATH);
  revalidatePath(`${LIST_PATH}/${result.result_id}/edit`);
  redirect(`${LIST_PATH}?updated=${operation === "delete" ? "deleted" : "saved"}`);
}

export async function createStaffBlockedPeriod(formData) {
  return runBlockedPeriodAction(formData, "create");
}

export async function createStaffBlockedPeriodState(_previousState, formData) {
  return runBlockedPeriodAction(formData, "create");
}

export async function updateStaffBlockedPeriod(formData) {
  return runBlockedPeriodAction(formData, "update");
}

export async function updateStaffBlockedPeriodState(_previousState, formData) {
  return runBlockedPeriodAction(formData, "update");
}

export async function deleteStaffBlockedPeriod(formData) {
  return runBlockedPeriodAction(formData, "delete");
}

export async function deleteStaffBlockedPeriodState(_previousState, formData) {
  return runBlockedPeriodAction(formData, "delete");
}
