"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function withQuery(path, values) {
  const searchParams = new URLSearchParams();

  for (const [key, value] of Object.entries(values)) {
    if (value) searchParams.set(key, value);
  }

  const query = searchParams.toString();
  return query ? `${path}?${query}` : path;
}

function reviewErrorCode(error) {
  const message = error?.message ?? "";

  if (message.includes("職員")) return "forbidden";
  if (message.includes("見つかりません")) return "not-found";
  if (message.includes("理由")) return "reason-required";
  if (message.includes("2000文字")) return "reason-too-long";
  if (message.includes("開始日時")) return "start-date-passed";
  if (message.includes("申請済み") || message.includes("審査中")) {
    return "invalid-status";
  }

  return "update-failed";
}

async function runReviewAction(formData, reviewAction) {
  const applicationId = getText(formData, "applicationId");

  if (!UUID_PATTERN.test(applicationId)) {
    redirect(withQuery("/staff", { error: "invalid-application" }));
  }

  const { supabase } = await requireStaff("/staff");
  const { data: application, error: lookupError } = await supabase
    .from("applications")
    .select("camp_id")
    .eq("id", applicationId)
    .maybeSingle();

  if (lookupError || !application || !UUID_PATTERN.test(application.camp_id)) {
    redirect(withQuery("/staff", { error: "not-found" }));
  }

  const applicationPath =
    `/staff/camps/${application.camp_id}/applications/${applicationId}`;
  const reason = getText(formData, "reason");

  if (
    (reviewAction === "request_revision" || reviewAction === "reject") &&
    !reason
  ) {
    redirect(withQuery(applicationPath, { error: "reason-required" }));
  }

  if (reason.length > 2000) {
    redirect(withQuery(applicationPath, { error: "reason-too-long" }));
  }

  const { data, error } = await supabase.rpc("review_camp_application", {
    target_application_id: applicationId,
    review_action: reviewAction,
    public_reason: reason || null,
  });

  if (error) {
    redirect(
      withQuery(applicationPath, {
        error: reviewErrorCode(error),
      }),
    );
  }

  const result = Array.isArray(data) ? data[0] : null;
  const status = result?.result_status ?? "updated";

  revalidatePath(applicationPath);
  revalidatePath(`/staff/camps/${application.camp_id}/applications`);
  revalidatePath("/staff");
  revalidatePath(`/user/applications/${applicationId}`);
  redirect(withQuery(applicationPath, { updated: status }));
}

export async function startCampApplicationReview(formData) {
  return runReviewAction(formData, "start_review");
}

export async function requestCampApplicationRevision(formData) {
  return runReviewAction(formData, "request_revision");
}

export async function rejectCampApplication(formData) {
  return runReviewAction(formData, "reject");
}
