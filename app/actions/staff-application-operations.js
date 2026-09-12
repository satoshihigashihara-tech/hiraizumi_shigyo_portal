"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { getText } from "@/utils/calendar/validation";
import { isUuid, isUpdatedAt, validatePayment, paymentFailure, stayFailure, noteFailure } from "@/utils/application-operations/validation";

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

async function updateStay(formData, operation) {
  const { supabase } = await requireStaff("/staff");
  const fields = Object.fromEntries(["applicationId", "updatedAt"].map((name) => [name, getText(formData, name)]));
  if (!isUuid(fields.applicationId)) return stayFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return stayFailure("invalid-version", fields);
  const { data: current, error: readError } = await supabase.rpc("get_application_stay", { target_application_id: fields.applicationId });
  if (readError) return stayFailure(readError, fields);
  if (current?.id !== fields.applicationId || !isUpdatedAt(current.updated_at)) return stayFailure("update-failed", fields);
  if (current.updated_at !== fields.updatedAt) return stayFailure("stale-update", fields);
  if (current.status !== "approved") return stayFailure("invalid-status", fields);
  if (current.stay?.status === "moved_out") return stayFailure("stay-completed", fields);
  if (current.stay?.status !== (operation === "check_in" ? "before_move_in" : "staying")) return stayFailure("invalid-stay", fields);
  // The preview is not authorization to mutate: RPC repeats all checks under locks.
  const { data, error } = await supabase.rpc("update_application_stay", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt, stay_action: operation,
  });
  if (error) return stayFailure(error, fields);
  const result = Array.isArray(data) && data.length === 1 ? data[0] : null;
  if (result?.result_id !== fields.applicationId || !isUpdatedAt(result.result_updated_at)
    || result.result_status !== (operation === "check_in" ? "staying" : "moved_out")
    || !["camp", "community_individual"].includes(result.result_usage_type)
    || (result.result_usage_type === "camp" ? !isUuid(result.result_camp_id) : result.result_camp_id !== null)) {
    return stayFailure("update-failed", fields);
  }
  const base = result.result_usage_type === "camp" ? `/staff/camps/${result.result_camp_id}` : "/staff/community";
  const path = `${base}/applications/${fields.applicationId}`;
  for (const route of [path, base, `${base}/applications`, "/staff", "/staff/calendar", "/calendar", "/user", "/user/applications",
    ...["", "/edit", "/confirm", "/complete"].map((suffix) => `/user/applications/${fields.applicationId}${suffix}`)]) revalidatePath(route);
  if (result.result_usage_type === "camp") {
    revalidatePath(`${base}/eligible-users`);
    revalidatePath(`${base}/room-plan`);
    revalidatePath("/user/camp-room");
  }
  redirect(`${path}?updated=${operation === "check_in" ? "checked-in" : "checked-out"}`);
}

export async function checkInApplication(formData) { return updateStay(formData, "check_in"); }
export async function checkOutApplication(formData) { return updateStay(formData, "check_out"); }

// useActionState adapters keep the existing one-argument actions reusable by
// Server Component forms and avoid changing their tested input contract.
export async function updateApplicationPaymentState(_previousState, formData) {
  return updateApplicationPayment(formData);
}

export async function checkInApplicationState(_previousState, formData) {
  return checkInApplication(formData);
}

export async function checkOutApplicationState(_previousState, formData) {
  return checkOutApplication(formData);
}

export async function saveApplicationStaffNote(formData) {
  const { supabase } = await requireStaff("/staff");
  const fields = Object.fromEntries(["applicationId", "updatedAt", "noteId", "body"].map((name) => [name, getText(formData, name)]));
  if (!isUuid(fields.applicationId)) return noteFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return noteFailure("invalid-version", fields);
  if (fields.noteId && !isUuid(fields.noteId)) return noteFailure("invalid-note", fields);
  if (!fields.body) return noteFailure("note-required", fields);
  if (Array.from(fields.body).length > 2000) return noteFailure("note-too-long", fields);
  const { data, error } = await supabase.rpc("save_application_staff_note", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt,
    target_note_id: fields.noteId || null, note_body: fields.body,
  });
  if (error) return noteFailure(error, fields);
  const result = Array.isArray(data) && data.length === 1 ? data[0] : null;
  if (result?.result_id !== fields.applicationId || !isUpdatedAt(result.result_updated_at) || !isUuid(result.result_note_id)
    || (fields.noteId && fields.noteId !== result.result_note_id) || !["camp", "community_individual"].includes(result.result_usage_type)
    || (result.result_usage_type === "camp" ? !isUuid(result.result_camp_id) : result.result_camp_id !== null)) return noteFailure("update-failed", fields);
  const base = result.result_usage_type === "camp" ? `/staff/camps/${result.result_camp_id}` : "/staff/community";
  const path = `${base}/applications/${fields.applicationId}`;
  for (const route of [path, base, `${base}/applications`, "/staff"]) revalidatePath(route);
  // Refresh parent versions without ever putting the note in an owner response.
  for (const suffix of ["", "/edit", "/confirm"]) revalidatePath(`/user/applications/${fields.applicationId}${suffix}`);
  redirect(`${path}?updated=note-saved`);
}

export async function saveApplicationStaffNoteState(_previousState, formData) {
  return saveApplicationStaffNote(formData);
}
