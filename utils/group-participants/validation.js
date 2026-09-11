import { getText, isUuid, isUpdatedAt } from "@/utils/calendar/validation";

export { isUuid, isUpdatedAt };
export const PARTICIPANT_FIELDS = {
  applicantName: "user_name", applicantAddress: "user_address", applicantPhone: "user_phone",
  emergencyContactName: "emergency_name", emergencyContactAddress: "emergency_address",
  emergencyContactPhone: "emergency_phone", notes: "special_notes",
  guardianConsentRequired: "requires_guardian_consent",
};
const LIMITS = { applicantName: 100, applicantAddress: 500, applicantPhone: 20,
  emergencyContactName: 100, emergencyContactAddress: 500, emergencyContactPhone: 20, notes: 2000 };
const CODES = new Set(["invalid-application", "invalid-version", "stale-update", "invalid-fields", "required-fields",
  "field-too-long", "invalid-phone", "not-found", "not-editable", "not-submittable", "participant-deadline-passed",
  "guardian-consent", "invalid-email", "duplicate-stay", "calendar-inconsistent", "group-member-inconsistent",
  "confirmation-required", "invalid-submission-key", "forbidden", "load-failed", "update-failed"]);

export const booleanField = (value) => ["true", "on", "1"].includes(value) ? true : ["false", "off", "0"].includes(value) ? false : null;
export function readParticipantFields(formData) {
  return Object.fromEntries([...Object.keys(PARTICIPANT_FIELDS), "applicationId", "updatedAt", "intent", "submissionKey", "confirmed"]
    .map((name) => [name, getText(formData, name)]));
}
export function toParticipantDatabaseFields(fields) {
  return Object.fromEntries(Object.entries(PARTICIPANT_FIELDS).map(([name, column]) =>
    [column, name === "guardianConsentRequired" ? booleanField(fields[name]) : fields[name] || null]));
}
export function validateParticipantFields(fields) {
  const errors = {};
  for (const [name, max] of Object.entries(LIMITS)) if (Array.from(fields[name] || "").length > max) errors[name] = "field-too-long";
  for (const name of ["applicantPhone", "emergencyContactPhone"])
    if (fields[name] && !/^[0-9+][0-9() -]{7,19}$/.test(fields[name])) errors[name] = "invalid-phone";
  if (fields.guardianConsentRequired && booleanField(fields.guardianConsentRequired) === null) errors.guardianConsentRequired = "invalid-fields";
  return errors;
}
export function participantErrorCode(error) {
  if (typeof error === "string") return CODES.has(error) ? error : "update-failed";
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  return CODES.has(error?.message) ? error.message : "update-failed";
}
export function participantFailure(error, fields = {}, fieldErrors = {}) {
  const code = participantErrorCode(error);
  const field = { "invalid-application": "applicationId", "invalid-version": "updatedAt",
    "guardian-consent": "guardianConsentRequired", "confirmation-required": "confirmed" }[code];
  return { error: code, fields, fieldErrors: field ? { ...fieldErrors, [field]: code } : fieldErrors };
}
