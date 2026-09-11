import { getText, isDate, isUuid, isUpdatedAt } from "@/utils/calendar/validation";

export { isUuid, isUpdatedAt };

export const GROUP_FIELD_NAMES = {
  groupName: "group_name",
  representativeName: "representative_name",
  representativeAddress: "representative_address",
  representativePhone: "representative_phone",
  startDate: "start_date",
  endDate: "end_date",
  usagePlace: "usage_place",
  purpose: "purpose",
  localActivity: "local_activity",
  notes: "special_notes",
  plannedParticipants: "planned_participants",
  representativeStays: "representative_stays",
};

const LIMITS = {
  groupName: 120,
  representativeName: 100,
  representativeAddress: 500,
  representativePhone: 20,
  purpose: 2000,
  localActivity: 2000,
  notes: 2000,
};

const ERROR_CODES = new Set([
  "invalid-group", "invalid-application", "invalid-fields", "required-fields", "field-too-long", "invalid-phone",
  "invalid-place", "invalid-period", "invalid-duration", "invalid-participant-count", "start-too-soon",
  "end-too-late", "invalid-email", "not-found", "not-editable", "not-submittable", "invalid-version",
  "stale-update", "calendar-unavailable", "calendar-inconsistent", "confirmation-required",
  "invalid-submission-key", "forbidden", "load-failed", "invalid-page",
  "invalid-action", "invalid-status", "invalid-room", "invalid-room-plan", "duplicate-room",
  "room-required", "room-capacity-full", "facility-capacity-full", "allocation-count-mismatch",
  "purpose-review-required", "participants-not-approved", "reason-required", "reason-too-long",
  "invalid-deadline", "staff-required", "participant-deadline-passed", "representative-participant",
  "stay-started", "invalid-stay",
]);

export function booleanField(value) {
  if (["true", "on", "1"].includes(value)) return true;
  if (["false", "off", "0"].includes(value)) return false;
  return null;
}

export function readGroupFields(formData) {
  return Object.fromEntries([...Object.keys(GROUP_FIELD_NAMES), "groupId", "updatedAt", "intent", "submissionKey", "confirmed", "reason"]
    .map((key) => [key, getText(formData, key)]));
}

export function toGroupDatabaseFields(fields, partial = false) {
  return Object.fromEntries(Object.entries(GROUP_FIELD_NAMES)
    .filter(([name]) => !partial || Object.hasOwn(fields, name))
    .map(([name, column]) => {
      if (name === "representativeStays") return [column, booleanField(fields[name])];
      if (name === "plannedParticipants") return [column, fields[name] ? Number(fields[name]) : null];
      return [column, fields[name] || null];
    }));
}

export function validateGroupFields(fields, complete = false) {
  const errors = {};
  for (const [name, max] of Object.entries(LIMITS)) {
    if (Array.from(fields[name] || "").length > max) errors[name] = "field-too-long";
  }
  if (fields.representativePhone && !/^[0-9+][0-9() -]{7,19}$/.test(fields.representativePhone)) {
    errors.representativePhone = "invalid-phone";
  }
  if (fields.usagePlace && fields.usagePlace !== "common_and_second_floor") errors.usagePlace = "invalid-place";
  if (fields.plannedParticipants && (!/^\d+$/.test(fields.plannedParticipants)
    || Number(fields.plannedParticipants) < 2 || Number(fields.plannedParticipants) > 15)) {
    errors.plannedParticipants = "invalid-participant-count";
  }
  if (fields.representativeStays && booleanField(fields.representativeStays) === null) {
    errors.representativeStays = "invalid-fields";
  }
  if (fields.startDate || fields.endDate) {
    if (!isDate(fields.startDate)) errors.startDate = "invalid-period";
    if (!isDate(fields.endDate)) errors.endDate = "invalid-period";
    if (!errors.startDate && !errors.endDate) {
      const days = (Date.parse(`${fields.endDate}T00:00:00Z`) - Date.parse(`${fields.startDate}T00:00:00Z`)) / 86400000 + 1;
      if (days < 2 || days > 15) errors.endDate = "invalid-duration";
    }
  }
  if (complete) {
    for (const name of Object.keys(GROUP_FIELD_NAMES).filter((name) => name !== "notes")) {
      if (!fields[name]) errors[name] = "required-fields";
    }
  }
  return errors;
}

export function groupErrorCode(error) {
  if (typeof error === "string") return ERROR_CODES.has(error) ? error : "update-failed";
  if (["40001", "40P01"].includes(error?.code)) return "stale-update";
  if (error?.code === "42501") return "forbidden";
  return ERROR_CODES.has(error?.message) ? error.message : "update-failed";
}

export function groupFailure(error, fields = {}, fieldErrors = {}) {
  const code = groupErrorCode(error);
  const field = {
    "start-too-soon": "startDate", "end-too-late": "endDate", "invalid-duration": "endDate",
    "invalid-participant-count": "plannedParticipants", "confirmation-required": "confirmed",
    "invalid-version": "updatedAt", "invalid-place": "usagePlace",
    "reason-required": "reason", "reason-too-long": "reason",
  }[code];
  return { error: code, fields, fieldErrors: field ? { ...fieldErrors, [field]: code } : fieldErrors };
}
