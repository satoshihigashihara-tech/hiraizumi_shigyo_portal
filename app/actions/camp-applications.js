"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

function getCheckbox(formData, name) {
  const value = formData.get(name);
  return value === "on" || value === "true" || value === "1";
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

async function getAuthenticatedClient(returnTo) {
  const supabase = await createClient();
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user) {
    redirect(withQuery("/login", { returnTo }));
  }

  return supabase;
}

export async function createCampApplicationDraft(formData) {
  const entryPath = "/user/applications/new/camp";
  const campId = getRequiredUuid(formData, "campId");

  if (!campId) {
    redirect(withQuery(entryPath, { error: "invalid-camp" }));
  }

  const supabase = await getAuthenticatedClient(entryPath);
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
  redirect(`/user/applications/${applicationId}/edit`);
}

export async function saveCampApplicationDraft(formData) {
  const applicationId = getRequiredUuid(formData, "applicationId");

  if (!applicationId) {
    redirect(withQuery("/user", { error: "invalid-application" }));
  }

  const applicationPath = `/user/applications/${applicationId}`;
  const editPath = `${applicationPath}/edit`;
  const confirmPath = `${applicationPath}/confirm`;
  const supabase = await getAuthenticatedClient(editPath);
  const roomPreference = getText(formData, "requestedRoomPreference");
  const intent = getText(formData, "intent");

  const { error } = await supabase.rpc("save_camp_application_draft", {
    target_application_id: applicationId,
    applicant_name: getText(formData, "applicantName"),
    applicant_address: getText(formData, "applicantAddress"),
    applicant_phone: getText(formData, "applicantPhone"),
    emergency_contact_name: getText(formData, "emergencyContactName"),
    emergency_contact_address: getText(
      formData,
      "emergencyContactAddress",
    ),
    emergency_contact_phone: getText(formData, "emergencyContactPhone"),
    usage_purpose: getText(formData, "usagePurpose"),
    notes: getText(formData, "notes"),
    guardian_consent_required: getCheckbox(
      formData,
      "guardianConsentRequired",
    ),
    requested_room_preference: roomPreference || null,
  });

  if (error) {
    redirect(
      withQuery(editPath, {
        error: databaseErrorCode(error),
      }),
    );
  }

  revalidatePath(applicationPath);
  revalidatePath("/user");

  if (intent === "confirm") {
    redirect(confirmPath);
  }

  redirect(withQuery(editPath, { saved: "1" }));
}

export async function submitCampApplication(formData) {
  const applicationId = getRequiredUuid(formData, "applicationId");

  if (!applicationId) {
    redirect(withQuery("/user", { error: "invalid-application" }));
  }

  const applicationPath = `/user/applications/${applicationId}`;
  const editPath = `${applicationPath}/edit`;
  const confirmPath = `${applicationPath}/confirm`;
  const completePath = `${applicationPath}/complete`;
  const supabase = await getAuthenticatedClient(confirmPath);
  const { data, error } = await supabase.rpc("submit_camp_application", {
    target_application_id: applicationId,
  });

  if (error) {
    redirect(
      withQuery(editPath, {
        error: databaseErrorCode(error),
      }),
    );
  }

  const result = Array.isArray(data) ? data[0] : null;
  const receptionNumber = result?.reception_number ?? "";

  revalidatePath("/staff/calendar");
  revalidatePath("/staff");
  revalidatePath("/staff/camps/[campId]/applications", "page");
  revalidatePath("/staff/camps/[campId]", "page");

  revalidatePath(applicationPath);
  revalidatePath("/user");
  redirect(
    withQuery(completePath, {
      receptionNumber,
    }),
  );
}
