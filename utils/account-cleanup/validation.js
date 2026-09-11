import "server-only";

import { getText, isUuid } from "@/utils/calendar/validation";

const CODES = new Set(["invalid-user", "reason-required", "reason-too-long", "not-found",
  "staff-protected", "account-protected", "manual-disable-not-eligible", "forbidden"]);

export function readAccountDisableFields(formData) {
  return Object.fromEntries(["userId", "reason"].map((name) => [name, getText(formData, name)]));
}

export function validateAccountDisable(fields) {
  if (!isUuid(fields.userId)) return "invalid-user";
  if (!fields.reason) return "reason-required";
  if (Array.from(fields.reason).length > 2000) return "reason-too-long";
  return null;
}

export function accountDisableFailure(error, fields = {}) {
  if (error?.code === "42501") return { error: "forbidden", fields };
  const code = typeof error === "string" ? error : error?.message;
  return { error: CODES.has(code) ? code : "update-failed", fields };
}
