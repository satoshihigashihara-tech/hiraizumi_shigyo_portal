import { getText, isUuid, isUpdatedAt } from "@/utils/calendar/validation";

export { isUuid, isUpdatedAt };

const TOKEN_PATTERN = /^[0-9a-f]{64}$/i;
const CODE_PATTERN = /^[A-HJ-NP-Z2-9]{16}$/;
const ERROR_CODES = new Set([
  "invalid-group", "invalid-application", "invalid-version", "stale-update", "invalid-invite",
  "invite-not-available", "invite-expired", "group-full", "duplicate-group-member", "duplicate-stay",
  "representative-not-staying", "group-member-inconsistent", "not-found", "forbidden", "load-failed",
]);

export function normalizeInvite(value, kind) {
  if (kind === "token") {
    const normalized = (value || "").toLowerCase();
    return TOKEN_PATTERN.test(normalized) ? normalized : null;
  }
  if (kind === "code") {
    const normalized = (value || "").toUpperCase().replace(/[-\s]/g, "");
    return CODE_PATTERN.test(normalized) ? normalized : null;
  }
  return null;
}

export function readInviteFields(formData) {
  return Object.fromEntries(["groupId", "updatedAt", "applicationId", "inviteValue", "inviteKind"]
    .map((name) => [name, getText(formData, name)]));
}

export function inviteErrorCode(error) {
  if (typeof error === "string") return ERROR_CODES.has(error) ? error : "update-failed";
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  return ERROR_CODES.has(error?.message) ? error.message : "update-failed";
}

export function inviteFailure(error, fields = {}) {
  const code = inviteErrorCode(error);
  const field = { "invalid-group": "groupId", "invalid-application": "applicationId",
    "invalid-version": "updatedAt", "invalid-invite": "inviteValue" }[code];
  return { error: code, fields, fieldErrors: field ? { [field]: code } : {} };
}
