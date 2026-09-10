"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const UPDATED_AT_PATTERN =
  /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-]([01]\d|2[0-3]):[0-5]\d)$/;

const REVIEW_ERROR_CODES = new Set([
  "not-found",
  "invalid-version",
  "stale-update",
  "invalid-status",
  "invalid-action",
  "reason-required",
  "reason-too-long",
  "start-date-passed",
  "invalid-room",
  "room-required",
  "invalid-allocation",
  "invalid-stay",
  "stay-completed",
  "camp-unavailable",
  "camp-dates-changed",
  "facility-capacity-full",
  "room-capacity-full",
]);

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

function isValidUpdatedAt(value) {
  if (!UPDATED_AT_PATTERN.test(value) || !Number.isFinite(Date.parse(value))) {
    return false;
  }

  const [year, month, day] = value.slice(0, 10).split("-").map(Number);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year > 0 && day <= monthDays[month - 1];
}

function reviewErrorCode(error) {
  const message = error?.message ?? "";

  if (message === "staff-required" || error?.code === "42501") {
    return "forbidden";
  }
  if (REVIEW_ERROR_CODES.has(message)) return message;
  if (error?.code === "40001" || error?.code === "40P01") return "stale-update";

  return "update-failed";
}

async function runStaffApplicationAction(formData, reviewAction) {
  const { supabase } = await requireStaff("/staff");
  const applicationId = getText(formData, "applicationId");

  if (!UUID_PATTERN.test(applicationId)) {
    redirect(withQuery("/staff", { error: "invalid-application" }));
  }

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
  const updatedAt = getText(formData, "updatedAt");

  if (!isValidUpdatedAt(updatedAt)) {
    redirect(withQuery(applicationPath, { error: "invalid-version" }));
  }

  const reason = getText(
    formData,
    reviewAction === "approve" ? "approvalComment" : "reason",
  );

  if (
    (reviewAction === "request_revision" || reviewAction === "reject") &&
    !reason
  ) {
    redirect(withQuery(applicationPath, { error: "reason-required" }));
  }

  if (Array.from(reason).length > 2000) {
    redirect(withQuery(applicationPath, { error: "reason-too-long" }));
  }

  // Pass the original DB string. Date conversion would discard microseconds.
  const rpcInput = {
    target_application_id: applicationId,
    expected_updated_at: updatedAt,
  };
  let rpcName = "review_camp_application";

  if (reviewAction === "assign_room") {
    const roomId = getText(formData, "roomId");
    if (!UUID_PATTERN.test(roomId)) {
      redirect(withQuery(applicationPath, { error: "invalid-room" }));
    }
    rpcName = "assign_camp_application_room";
    rpcInput.target_room_id = roomId;
    rpcInput.change_reason = reason || null;
  } else {
    rpcInput.review_action = reviewAction;
    rpcInput.public_reason = reason || null;
  }

  const { data, error } = await supabase.rpc(rpcName, rpcInput);

  if (error) {
    redirect(
      withQuery(applicationPath, {
        error: reviewErrorCode(error),
      }),
    );
  }

  const result = Array.isArray(data) ? data[0] : null;
  if (!result?.result_status || result.result_camp_id !== application.camp_id) {
    redirect(withQuery(applicationPath, { error: "update-failed" }));
  }

  revalidatePath(applicationPath);
  revalidatePath(`/staff/camps/${application.camp_id}/applications`);
  revalidatePath(`/staff/camps/${application.camp_id}`);
  revalidatePath("/staff");
  revalidatePath("/staff/calendar");
  revalidatePath(`/user/applications/${applicationId}`);
  revalidatePath("/user/applications");
  revalidatePath("/user");
  redirect(withQuery(applicationPath, {
    updated: reviewAction === "assign_room" ? "room-assigned" : result.result_status,
  }));
}

export async function startCampApplicationReview(formData) {
  return runStaffApplicationAction(formData, "start_review");
}

export async function requestCampApplicationRevision(formData) {
  return runStaffApplicationAction(formData, "request_revision");
}

export async function rejectCampApplication(formData) {
  return runStaffApplicationAction(formData, "reject");
}

export async function assignCampApplicationRoom(formData) {
  return runStaffApplicationAction(formData, "assign_room");
}

export async function approveCampApplication(formData) {
  return runStaffApplicationAction(formData, "approve");
}
