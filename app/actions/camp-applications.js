"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";
import { withMode } from "@/utils/navigation/mode";
import {
  campBoolean,
  campDraftFailure,
  readCampDraftFields,
  validateCampDraftFields,
} from "@/utils/camp-applications/validation";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function getRequiredUuid(formData, name) {
  const value = getText(formData, name);
  return UUID_PATTERN.test(value) ? value : null;
}

function getPositiveBigint(formData, name) {
  const value = getText(formData, name);
  return /^[1-9]\d*$/.test(value) ? value : null;
}

function withQuery(path, values) {
  const searchParams = new URLSearchParams();

  for (const [key, value] of Object.entries(values)) {
    if (value) {
      searchParams.set(key, value);
    }
  }

  const query = searchParams.toString();
  return query ? `${path}?${query}` : path;
}

function databaseErrorCode(error) {
  const message = error?.message ?? "";

  if (error?.code === "40001" || error?.code === "40P01") return "stale-update";
  if (message === "calendar-unavailable" || message === "calendar-inconsistent") return "calendar-unavailable";
  if (["stale-update", "invalid-version"].includes(message)) return "stale-update";
  if (message === "eligible-roster-required" || message === "eligible-roster-form-required") return "eligible-roster-required";
  if (message === "pdf-confirmation-required") return "pdf-confirmation-required";
  if (message === "pdf-prerequisites-unavailable") return "pdf-prerequisites-unavailable";
  if (message === "pdf-content-too-long") return "pdf-content-too-long";
  if (["pdf-assignment-unavailable", "pdf-room-not-printable", "pdf-calendar-unavailable"].includes(message)) return "pdf-unavailable";
  if (["pdf-not-ready", "job-unavailable"].includes(message)) return "pdf-not-ready";
  if (message === "required-fields") return "required-fields";
  if (message === "invalid-phone") return "invalid-phone";
  if (message === "guardian-consent") return "guardian-consent";
  if (message === "not-editable") return "not-editable";
  if (message === "not-submittable") return "not-submittable";
  if (message === "confirmation-required") return "confirmation-required";
  if (message === "field-too-long") return "field-too-long";
  if (message === "application-inconsistent" || message === "submitted-pdf-inconsistent") return "application-inconsistent";

  if (message.includes("ログイン")) return "login-required";
  if (message.includes("期限")) return "deadline-passed";
  if (message.includes("対象者")) return "not-eligible";
  if (message.includes("定員")) return "capacity-full";
  if (message.includes("必須項目")) return "required-fields";
  if (message.includes("電話番号")) return "invalid-phone";
  if (message.includes("保護者同意書")) return "guardian-consent";
  if (message.includes("編集")) return "not-editable";
  if (message.includes("提出")) return "not-submittable";
  if (message.includes("見つかりません")) return "not-found";

  return "unexpected";
}

export async function createCampApplicationDraft(formData) {
  const entryPath = withMode("/user/applications/new/camp", "camp");
  const { supabase } = await requireActiveUser(entryPath);
  const campId = getRequiredUuid(formData, "campId");

  if (!campId) {
    redirect(withQuery(entryPath, { error: "invalid-camp" }));
  }

  const { data: applicationId, error } = await supabase.rpc(
    "create_camp_application_draft",
    { target_camp_id: campId },
  );

  if (error || !UUID_PATTERN.test(applicationId ?? "")) {
    redirect(
      withQuery(entryPath, {
        error: databaseErrorCode(error),
      }),
    );
  }

  revalidatePath("/user");
  redirect(withMode(`/user/applications/${applicationId}/edit`, "camp"));
}

export async function saveCampApplicationDraft(previousState, formData) {
  const { supabase } = await requireActiveUser(withMode("/user/applications", "camp"));
  const applicationId = getRequiredUuid(formData, "applicationId");
  const fields = readCampDraftFields(formData);
  const intent = getText(formData, "intent");
  const roomAssignmentMode = getText(formData, "roomAssignmentMode");
  const eligibleRoster = roomAssignmentMode === "eligible_roster";
  const inputVersion = getPositiveBigint(formData, "inputVersion");

  if (!applicationId) {
    return campDraftFailure("invalid-application", fields);
  }

  const applicationPath = `/user/applications/${applicationId}`;
  const editPath = `${applicationPath}/edit`;
  const confirmPath = `${applicationPath}/confirm`;

  if (!["save", "confirm"].includes(intent)) {
    return campDraftFailure("invalid-action", fields);
  }

  if (eligibleRoster && !inputVersion) {
    return campDraftFailure("stale-update", fields);
  }

  const fieldErrors = validateCampDraftFields(fields, intent, { eligibleRoster });
  if (Object.keys(fieldErrors).length > 0) {
    return campDraftFailure(
      Object.values(fieldErrors)[0],
      fields,
      fieldErrors,
    );
  }

  const rpcName = eligibleRoster
    ? "save_camp_roster_application_draft"
    : "save_camp_application_draft";
  const rpcArguments = eligibleRoster
    ? {
        target_application_id: applicationId,
        expected_input_version: inputVersion,
        applicant_name: fields.applicantName,
        applicant_address: fields.applicantAddress,
        applicant_phone: fields.applicantPhone,
        emergency_contact_name: fields.emergencyContactName,
        emergency_contact_address: fields.emergencyContactAddress,
        emergency_contact_phone: fields.emergencyContactPhone,
        usage_purpose: fields.usagePurpose,
        notes: fields.notes,
        guardian_consent_required: campBoolean(fields.guardianConsentRequired),
      }
    : {
    target_application_id: applicationId,
    applicant_name: fields.applicantName,
    applicant_address: fields.applicantAddress,
    applicant_phone: fields.applicantPhone,
    emergency_contact_name: fields.emergencyContactName,
    emergency_contact_address: fields.emergencyContactAddress,
    emergency_contact_phone: fields.emergencyContactPhone,
    usage_purpose: fields.usagePurpose,
    notes: fields.notes,
    guardian_consent_required: campBoolean(
      fields.guardianConsentRequired,
    ),
    requested_room_preference: fields.requestedRoomPreference || null,
      };
  const { error } = await supabase.rpc(rpcName, rpcArguments);

  if (error) {
    return campDraftFailure(databaseErrorCode(error), fields);
  }

  if (
    intent === "confirm" &&
    campBoolean(fields.guardianConsentRequired) === true
  ) {
    const { data: consent, error: consentError } = await supabase
      .from("consent_documents")
      .select("id")
      .eq("application_id", applicationId)
      .maybeSingle();

    if (consentError) {
      return campDraftFailure("load-failed", fields);
    }
    if (!consent) {
      return campDraftFailure("guardian-consent", fields, {
        guardianConsentFile: "file-required",
      });
    }
  }

  revalidatePath(applicationPath);
  revalidatePath("/user");

  if (intent === "confirm") {
    redirect(withMode(confirmPath, "camp"));
  }

  redirect(withMode(withQuery(editPath, { saved: "1" }), "camp"));
}

export async function requestCampApplicationPdf(formData) {
  const { supabase } = await requireActiveUser(withMode("/user/applications", "camp"));
  const applicationId = getRequiredUuid(formData, "applicationId");
  const inputVersion = getPositiveBigint(formData, "inputVersion");
  const requestKey = getRequiredUuid(formData, "requestKey");
  if (!applicationId || !inputVersion || !requestKey) {
    redirect(withMode(withQuery("/user/applications", { error: "invalid-application" }), "camp"));
  }
  const confirmPath = `/user/applications/${applicationId}/confirm`;
  const { data, error } = await supabase.rpc("begin_camp_application_pdf", {
    target_application_id: applicationId,
    expected_input_version: inputVersion,
    request_key_value: requestKey,
  });
  if (error || !UUID_PATTERN.test(data ?? "")) {
    redirect(withMode(withQuery(confirmPath, { error: databaseErrorCode(error) }), "camp"));
  }
  revalidatePath(confirmPath);
  redirect(withMode(withQuery(confirmPath, { pdf: "requested" }), "camp"));
}

export async function submitCampApplication(formData) {
  const { supabase } = await requireActiveUser(withMode("/user/applications", "camp"));
  const applicationId = getRequiredUuid(formData, "applicationId");
  const pdfVersionId = getRequiredUuid(formData, "pdfVersionId");
  const inputVersion = getPositiveBigint(formData, "inputVersion");
  const submissionKey = getRequiredUuid(formData, "submissionKey");

  if (!applicationId) {
    redirect(withQuery("/user", { error: "invalid-application" }));
  }

  const applicationPath = `/user/applications/${applicationId}`;
  const editPath = `${applicationPath}/edit`;
  const confirmPath = `${applicationPath}/confirm`;
  const completePath = `${applicationPath}/complete`;

  if (getText(formData, "confirmed") !== "true") {
    redirect(withMode(withQuery(confirmPath, { error: "confirmation-required" }), "camp"));
  }

  const usePdfSubmission = Boolean(pdfVersionId || inputVersion || submissionKey);
  const { data, error } = usePdfSubmission
    ? await supabase.rpc("submit_camp_application_with_pdf", {
        target_application_id: applicationId,
        target_version_id: pdfVersionId,
        expected_input_version: inputVersion,
        submission_key_value: submissionKey,
        confirmed: true,
      })
    : await supabase.rpc("submit_camp_application", {
        target_application_id: applicationId,
      });

  if (error) {
    redirect(
      withMode(withQuery(editPath, {
        error: databaseErrorCode(error),
      }), "camp"),
    );
  }

  const result = Array.isArray(data) ? data[0] : null;
  if (
    !Array.isArray(data) ||
    data.length !== 1 ||
    result?.submitted_application_id !== applicationId ||
    !/^SG-\d{4}-\d+$/.test(result?.reception_number ?? "") ||
    !Number.isFinite(Date.parse(result?.submission_time ?? "")) ||
    (usePdfSubmission && result?.submitted_version_id !== pdfVersionId)
  ) {
    redirect(withMode(withQuery(editPath, { error: "unexpected" }), "camp"));
  }

  revalidatePath("/staff/calendar");
  revalidatePath("/staff");
  revalidatePath("/staff/camps/[campId]/applications", "page");
  revalidatePath("/staff/camps/[campId]", "page");

  revalidatePath(applicationPath);
  revalidatePath("/user");
  redirect(withMode(completePath, "camp"));
}
