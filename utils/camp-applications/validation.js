const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PHONE_PATTERN = /^[0-9+][0-9() -]{7,19}$/;

export const CAMP_FIELD_NAMES = [
  "applicantName",
  "applicantAddress",
  "applicantPhone",
  "emergencyContactName",
  "emergencyContactAddress",
  "emergencyContactPhone",
  "usagePlace",
  "usagePurpose",
  "notes",
  "guardianConsentRequired",
  "requestedRoomPreference",
];

const FIELD_LIMITS = {
  applicantName: 100,
  applicantAddress: 500,
  applicantPhone: 20,
  emergencyContactName: 100,
  emergencyContactAddress: 500,
  emergencyContactPhone: 20,
  usagePurpose: 2000,
  notes: 2000,
};

const REQUIRED_FOR_CONFIRM = [
  "applicantName",
  "applicantAddress",
  "applicantPhone",
  "emergencyContactName",
  "emergencyContactAddress",
  "emergencyContactPhone",
  "usagePlace",
  "usagePurpose",
  "guardianConsentRequired",
  "requestedRoomPreference",
];

export function isCampApplicationId(value) {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function campBoolean(value) {
  if (["true", "on", "1"].includes(value)) return true;
  if (["false", "off", "0"].includes(value)) return false;
  return null;
}

export function readCampDraftFields(formData) {
  return Object.fromEntries(
    CAMP_FIELD_NAMES.map((name) => {
      const value = formData.get(name);
      return [name, typeof value === "string" ? value.trim() : ""];
    }),
  );
}

export function validateCampDraftFields(fields, intent) {
  const errors = {};

  for (const [name, limit] of Object.entries(FIELD_LIMITS)) {
    if ((fields[name] ?? "").length > limit) {
      errors[name] = "field-too-long";
    }
  }

  for (const name of ["applicantPhone", "emergencyContactPhone"]) {
    if (fields[name] && !PHONE_PATTERN.test(fields[name])) {
      errors[name] = "invalid-phone";
    }
  }

  if (fields.usagePlace !== "common_and_second_floor") {
    errors.usagePlace = "invalid-place";
  }

  if (
    fields.guardianConsentRequired &&
    campBoolean(fields.guardianConsentRequired) === null
  ) {
    errors.guardianConsentRequired = "invalid-fields";
  }

  if (
    fields.requestedRoomPreference &&
    !["shared_ok", "private_requested"].includes(
      fields.requestedRoomPreference,
    )
  ) {
    errors.requestedRoomPreference = "invalid-fields";
  }

  if (intent === "confirm") {
    for (const name of REQUIRED_FOR_CONFIRM) {
      if (!fields[name]) errors[name] = "required-fields";
    }
  }

  return errors;
}

export function campDraftFailure(error, fields, fieldErrors = {}) {
  const code = typeof error === "string" && error ? error : "unexpected";
  return { error: code, fields, fieldErrors };
}
