import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";
import { isCampApplicationId } from "@/utils/camp-applications/validation";

const CAMP_ENTRY_PATH = "/user/applications/new/camp";
const CAMP_COLUMNS = [
  "id",
  "name",
  "start_date",
  "end_date",
  "application_deadline",
];
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function isValidDate(value) {
  if (typeof value !== "string" || !DATE_PATTERN.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

function isCamp(row) {
  return (
    row &&
    UUID_PATTERN.test(row.id ?? "") &&
    typeof row.name === "string" &&
    row.name.trim() !== "" &&
    isValidDate(row.start_date) &&
    isValidDate(row.end_date) &&
    row.start_date <= row.end_date &&
    typeof row.application_deadline === "string" &&
    Number.isFinite(Date.parse(row.application_deadline))
  );
}

function pickCamp(row) {
  return Object.fromEntries(
    CAMP_COLUMNS.map((column) => [column, row[column] ?? null]),
  );
}

/**
 * ログイン中の対象メールに紐づくキャンプだけを取得する。
 * camps のRLSが対象メール・削除状態を判定するため、画面へメールや対象者一覧を渡さない。
 */
export async function getEligibleCamps() {
  const { supabase } = await requireActiveUser(CAMP_ENTRY_PATH);
  const { data, error } = await supabase
    .from("camps")
    .select(CAMP_COLUMNS.join(","))
    .order("start_date", { ascending: true })
    .order("id", { ascending: true });

  if (error || !Array.isArray(data) || data.some((row) => !isCamp(row))) {
    return { error: "load-failed", camps: [] };
  }

  return { error: null, camps: data.map(pickCamp) };
}

const APPLICATION_COLUMNS = [
  "id",
  "status",
  "start_date",
  "end_date",
  "user_name",
  "user_address",
  "user_phone",
  "emergency_name",
  "emergency_address",
  "emergency_phone",
  "usage_place",
  "purpose",
  "special_notes",
  "requires_guardian_consent",
  "room_preference",
  "revision_due_at",
  "decision_reason",
  "updated_at",
  "camps(name,start_date,end_date)",
];

const PROFILE_COLUMNS = [
  "full_name",
  "address",
  "phone",
  "emergency_name",
  "emergency_address",
  "emergency_phone",
];

function hasSavedFields(application) {
  return [
    "user_name",
    "user_address",
    "user_phone",
    "emergency_name",
    "emergency_address",
    "emergency_phone",
    "usage_place",
    "purpose",
    "special_notes",
    "requires_guardian_consent",
    "room_preference",
  ].some((name) => application[name] !== null);
}

function initialFields(application, profile) {
  const saved = hasSavedFields(application);
  const value = (applicationName, profileName) =>
    saved ? application[applicationName] ?? "" : profile[profileName] ?? "";

  return {
    applicantName: value("user_name", "full_name"),
    applicantAddress: value("user_address", "address"),
    applicantPhone: value("user_phone", "phone"),
    emergencyContactName: value("emergency_name", "emergency_name"),
    emergencyContactAddress: value("emergency_address", "emergency_address"),
    emergencyContactPhone: value("emergency_phone", "emergency_phone"),
    usagePlace: application.usage_place ?? "common_and_second_floor",
    usagePurpose: application.purpose ?? "",
    notes: application.special_notes ?? "",
    guardianConsentRequired:
      application.requires_guardian_consent === null
        ? ""
        : String(application.requires_guardian_consent),
    requestedRoomPreference: application.room_preference ?? "",
  };
}

function isApplicationPayload(application, profile) {
  const applicationTextFields = [
    "user_name",
    "user_address",
    "user_phone",
    "emergency_name",
    "emergency_address",
    "emergency_phone",
    "usage_place",
    "purpose",
    "special_notes",
    "room_preference",
    "revision_due_at",
    "decision_reason",
    "updated_at",
  ];
  const profileTextFields = PROFILE_COLUMNS;
  const isNullableString = (value) =>
    value === null || typeof value === "string";

  return (
    application &&
    isCampApplicationId(application.id) &&
    [
      "draft",
      "submitted",
      "under_review",
      "revision_requested",
      "approved",
      "rejected",
      "cancellation_requested",
      "cancelled",
    ].includes(application.status) &&
    isValidDate(application.start_date) &&
    isValidDate(application.end_date) &&
    application.camps &&
    typeof application.camps.name === "string" &&
    typeof profile === "object" &&
    profile !== null &&
    applicationTextFields.every((name) =>
      isNullableString(application[name]),
    ) &&
    profileTextFields.every((name) => isNullableString(profile[name])) &&
    (application.requires_guardian_consent === null ||
      typeof application.requires_guardian_consent === "boolean")
  );
}

export async function getCampApplicationForEdit(applicationId) {
  const returnTo = isCampApplicationId(applicationId)
    ? `/user/applications/${applicationId}/edit`
    : "/user/applications";
  const { supabase, user } = await requireActiveUser(returnTo);

  if (!isCampApplicationId(applicationId)) {
    return { error: "not-found", application: null };
  }

  const [applicationResult, profileResult, consentResult] = await Promise.all([
    supabase
      .from("applications")
      .select(APPLICATION_COLUMNS.join(","))
      .eq("id", applicationId)
      .eq("user_id", user.id)
      .eq("usage_type", "camp")
      .maybeSingle(),
    supabase
      .from("profiles")
      .select(PROFILE_COLUMNS.join(","))
      .eq("id", user.id)
      .maybeSingle(),
    supabase
      .from("consent_documents")
      .select("id,mime_type,size_bytes,updated_at")
      .eq("application_id", applicationId)
      .maybeSingle(),
  ]);

  const application = applicationResult.data;
  const profile = profileResult.data;
  const consent = consentResult.data;

  if (
    applicationResult.error ||
    profileResult.error ||
    consentResult.error ||
    !isApplicationPayload(application, profile) ||
    (consent &&
      (!isCampApplicationId(consent.id) ||
        !["application/pdf", "image/jpeg", "image/png"].includes(
          consent.mime_type,
        ) ||
        !Number.isInteger(consent.size_bytes) ||
        consent.size_bytes < 1 ||
        consent.size_bytes > 5 * 1024 * 1024))
  ) {
    return {
      error: application ? "load-failed" : "not-found",
      application: null,
    };
  }

  return {
    error: null,
    application: {
      id: application.id,
      status: application.status,
      campName: application.camps.name,
      startDate: application.start_date,
      endDate: application.end_date,
      revisionDueAt: application.revision_due_at,
      revisionReason:
        application.status === "revision_requested"
          ? application.decision_reason ?? ""
          : "",
      updatedAt: application.updated_at,
      fields: initialFields(application, profile),
      consent: consent
        ? {
            mimeType: consent.mime_type,
            sizeBytes: consent.size_bytes,
            updatedAt: consent.updated_at,
          }
        : null,
    },
  };
}
