import { isDate, isUuid, isUpdatedAt } from "@/utils/calendar/validation";

export { isUuid, isUpdatedAt };
const CODES = new Set(["invalid-application", "invalid-version", "stale-update", "invalid-status",
  "invalid-payment-status", "invalid-payment-deadline", "reason-required", "reason-too-long",
  "charge-not-found", "not-found", "forbidden", "update-failed"]);

export function paymentErrorCode(error) {
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  const code = typeof error === "string" ? error : error?.message;
  return CODES.has(code) ? code : "update-failed";
}

export function paymentFailure(error, fields) {
  const code = paymentErrorCode(error);
  const field = { "invalid-application": "applicationId", "invalid-version": "updatedAt",
    "invalid-payment-status": "paymentStatus", "invalid-payment-deadline": "paymentDueDate",
    "reason-required": "reason", "reason-too-long": "reason" }[code];
  return { error: code, fields, fieldErrors: field ? { [field]: code } : {} };
}

export function validatePayment(fields) {
  if (!isUuid(fields.applicationId)) return "invalid-application";
  if (!isUpdatedAt(fields.updatedAt)) return "invalid-version";
  if (!["unpaid", "paid"].includes(fields.paymentStatus)) return "invalid-payment-status";
  if (fields.paymentDueDate && !isDate(fields.paymentDueDate)) return "invalid-payment-deadline";
  if (Array.from(fields.reason).length > 2000) return "reason-too-long";
  return null;
}

// Derived at read time, without shared caching or any state mutation.
export function isPaymentOverdue(charge, now = new Date()) {
  if (charge?.payment_status !== "unpaid" || !isDate(charge.payment_due_date)) return false;
  const today = new Date(now.getTime() + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);
  return charge.payment_due_date < today;
}

const STAY_CODES = new Set(["invalid-application", "invalid-version", "stale-update", "invalid-status",
  "invalid-action", "invalid-stay", "stay-completed", "invalid-allocation", "calendar-inconsistent",
  "outside-stay-period", "camp-unavailable", "camp-dates-changed", "calendar-unavailable", "duplicate-stay",
  "invalid-room", "room-capacity-full", "facility-capacity-full", "capacity-full", "not-found", "forbidden"]);

export function stayErrorCode(error) {
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  const code = typeof error === "string" ? error : error?.message;
  return STAY_CODES.has(code) ? code : "update-failed";
}

export function stayFailure(error, fields) {
  const code = stayErrorCode(error);
  const field = { "invalid-application": "applicationId", "invalid-version": "updatedAt" }[code];
  return { error: code, fields, fieldErrors: field ? { [field]: code } : {} };
}

const NOTE_CODES = new Set(["invalid-application", "invalid-version", "stale-update", "invalid-note",
  "note-required", "note-too-long", "note-not-found", "not-found", "forbidden"]);
export function noteErrorCode(error) {
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  const code = typeof error === "string" ? error : error?.message;
  return NOTE_CODES.has(code) ? code : "update-failed";
}
export function noteFailure(error, fields) {
  const code = noteErrorCode(error);
  const field = { "invalid-application": "applicationId", "invalid-version": "updatedAt", "invalid-note": "noteId",
    "note-required": "body", "note-too-long": "body" }[code];
  return { error: code, fields, fieldErrors: field ? { [field]: code } : {} };
}
