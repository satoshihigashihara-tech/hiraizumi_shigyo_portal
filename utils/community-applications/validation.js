import { getText, isDate, isUuid, isUpdatedAt } from "@/utils/calendar/validation";

export { isUuid, isUpdatedAt };
export const FIELD_NAMES = {
  applicantName: "user_name", applicantAddress: "user_address", applicantPhone: "user_phone",
  emergencyContactName: "emergency_name", emergencyContactAddress: "emergency_address",
  emergencyContactPhone: "emergency_phone", usagePurpose: "purpose", localActivity: "local_activity",
  notes: "special_notes", usagePlace: "usage_place", startDate: "start_date", endDate: "end_date",
  guardianConsentRequired: "requires_guardian_consent",
};
const LIMITS = { applicantName: 100, applicantAddress: 500, applicantPhone: 20, emergencyContactName: 100,
  emergencyContactAddress: 500, emergencyContactPhone: 20, usagePurpose: 2000, localActivity: 2000, notes: 2000 };
const CODES = new Set(["invalid-application", "invalid-fields", "required-fields", "field-too-long", "invalid-phone",
  "invalid-place", "invalid-period", "invalid-duration", "start-too-soon", "end-too-late", "invalid-email",
  "not-found", "not-editable", "not-submittable", "invalid-version", "stale-update", "revision-expired",
  "calendar-unavailable", "calendar-inconsistent", "duplicate-stay", "capacity-full", "guardian-consent",
  "confirmation-required", "invalid-submission-key", "invalid-action", "invalid-status", "reason-required",
  "reason-too-long", "invalid-deadline", "invalid-path", "invalid-type", "invalid-size", "forbidden", "load-failed",
  "invalid-room", "room-required", "invalid-allocation", "invalid-stay", "stay-completed",
  "stay-started", "room-capacity-full", "facility-capacity-full", "application-inconsistent"]);

export function booleanField(value) {
  if (["true", "on", "1"].includes(value)) return true;
  if (["false", "off", "0"].includes(value)) return false;
  return null;
}

export function readFields(formData) {
  const fields = Object.fromEntries([...Object.keys(FIELD_NAMES), "applicationId", "updatedAt", "intent", "submissionKey", "confirmed"]
    .map((key) => [key, getText(formData, key)]));
  return fields;
}

export function toDatabaseFields(fields, partial = false) {
  return Object.fromEntries(Object.entries(FIELD_NAMES)
    .filter(([name]) => !partial || Object.hasOwn(fields, name))
    .map(([name, column]) => [column, name === "guardianConsentRequired" ? booleanField(fields[name]) : fields[name] || null]));
}

export function validateFields(fields, complete = false) {
  const errors = {};
  for (const [name, max] of Object.entries(LIMITS)) {
    if (Array.from(fields[name] || "").length > max) errors[name] = "field-too-long";
  }
  for (const name of ["applicantPhone", "emergencyContactPhone"]) {
    if (fields[name] && !/^[0-9+][0-9() -]{7,19}$/.test(fields[name])) errors[name] = "invalid-phone";
  }
  if (fields.usagePlace && fields.usagePlace !== "common_and_second_floor") errors.usagePlace = "invalid-place";
  if (fields.guardianConsentRequired && booleanField(fields.guardianConsentRequired) === null) errors.guardianConsentRequired = "invalid-fields";
  if (fields.startDate || fields.endDate) {
    if (!isDate(fields.startDate)) errors.startDate = "invalid-period";
    if (!isDate(fields.endDate)) errors.endDate = "invalid-period";
    if (!errors.startDate && !errors.endDate) {
      const days = (Date.parse(`${fields.endDate}T00:00:00Z`) - Date.parse(`${fields.startDate}T00:00:00Z`)) / 86400000 + 1;
      if (days < 2 || days > 15) errors.endDate = "invalid-duration";
    }
  }
  if (complete) {
    for (const name of Object.keys(FIELD_NAMES).filter((name) => name !== "notes")) {
      if (!fields[name]) errors[name] = "required-fields";
    }
  }
  return errors;
}

export function communityErrorCode(error) {
  if (typeof error === "string") return CODES.has(error) ? error : "update-failed";
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  return CODES.has(error?.message) ? error.message : "update-failed";
}

export function communityFailure(error, fields = {}, fieldErrors = {}) {
  const code = communityErrorCode(error);
  const field = { "start-too-soon": "startDate", "end-too-late": "endDate", "invalid-duration": "endDate",
    "guardian-consent": "guardianConsentRequired", "confirmation-required": "confirmed",
    "invalid-version": "updatedAt", "invalid-place": "usagePlace", "invalid-deadline": "revisionDeadline",
    "reason-required": "reason", "reason-too-long": "reason",
    "invalid-room": "roomId", "room-required": "roomId", "room-capacity-full": "roomId" }[code];
  return { error: code, fields, fieldErrors: field ? { ...fieldErrors, [field]: code } : fieldErrors };
}
