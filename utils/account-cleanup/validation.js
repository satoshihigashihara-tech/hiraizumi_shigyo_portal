import "server-only";

import { getText, isUuid } from "@/utils/calendar/validation";

const CODES = new Set(["invalid-application", "reason-required", "reason-too-long",
  "confirmation-required", "not-found", "staff-protected", "account-protected",
  "manual-disable-not-eligible", "forbidden"]);

export function readAccountDisableFields(formData) {
  return Object.fromEntries(["applicationId", "reason", "confirmed"]
    .map((name) => [name, getText(formData, name)]));
}

export function validateAccountDisable(fields) {
  if (!isUuid(fields.applicationId)) return "invalid-application";
  if (!fields.reason) return "reason-required";
  if (Array.from(fields.reason).length > 2000) return "reason-too-long";
  if (fields.confirmed !== "true") return "confirmation-required";
  return null;
}

export function accountDisableFailure(error, fields = {}) {
  if (error?.code === "42501") return { error: "forbidden", fields };
  const code = typeof error === "string" ? error : error?.message;
  const stableCode = CODES.has(code) ? code : "update-failed";
  const field = stableCode === "reason-required" || stableCode === "reason-too-long"
    ? "reason"
    : stableCode === "confirmation-required" ? "confirmed" : null;
  return {
    error: stableCode,
    fields,
    fieldErrors: field ? { [field]: stableCode } : {},
  };
}
