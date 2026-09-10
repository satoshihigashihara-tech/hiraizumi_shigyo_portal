"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import {
  getText, isUuid, isUpdatedAt, toTokyoDeadline, periodError, reasonError,
  calendarErrorCode, calendarFailure,
} from "@/utils/calendar/validation";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function withQuery(path, values) {
  const searchParams = new URLSearchParams();

  for (const [key, value] of Object.entries(values)) {
    if (value !== "" && value !== null && value !== undefined) {
      searchParams.set(key, String(value));
    }
  }

  const query = searchParams.toString();
  return query ? `${path}?${query}` : path;
}

function revalidateCamp(campId) {
  for (const path of ["/calendar", "/staff/calendar", "/staff", "/staff/camps", "/user", "/user/applications",
    `/staff/camps/${campId}`, `/staff/camps/${campId}/edit`, `/staff/camps/${campId}/applications`]) {
    revalidatePath(path);
  }
  revalidatePath("/user/applications/[applicationId]", "page");
  revalidatePath("/user/applications/[applicationId]/edit", "page");
  revalidatePath("/user/applications/[applicationId]/confirm", "page");
}

async function runCampAction(formData, operation) {
  const { supabase } = await requireStaff("/staff/camps");
  const fields = Object.fromEntries([
    "campId", "campName", "startDate", "endDate", "applicationDeadline", "updatedAt", "reason",
  ].map((key) => [key, getText(formData, key)]));
  const editing = operation !== "create";
  if (editing && !isUuid(fields.campId)) return calendarFailure("not-found", fields);
  if (editing && !isUpdatedAt(fields.updatedAt)) return calendarFailure("invalid-version", fields);
  const invalidReason = reasonError(fields.reason, operation === "delete");
  if (invalidReason) return calendarFailure(invalidReason, fields);
  const input = editing ? {
    target_camp_id: fields.campId, expected_updated_at: fields.updatedAt, change_reason: fields.reason || null,
  } : {};
  if (operation !== "delete") {
    const invalidPeriod = periodError(fields.startDate, fields.endDate);
    if (invalidPeriod) return calendarFailure(invalidPeriod, fields);
    if (!fields.campName || Array.from(fields.campName).length > 120) return calendarFailure("invalid-name", fields);
    const deadline = toTokyoDeadline(fields.applicationDeadline);
    if (!deadline || Date.parse(deadline) > Date.parse(`${fields.startDate}T00:00:00+09:00`)) {
      return calendarFailure("invalid-deadline", fields);
    }
    Object.assign(input, {
      camp_name: fields.campName, camp_start_date: fields.startDate, camp_end_date: fields.endDate,
      camp_application_deadline: deadline,
    });
  }
  const rpcName = { create: "create_staff_camp", update: "update_staff_camp", delete: "delete_staff_camp" }[operation];
  const { data, error } = await supabase.rpc(rpcName, input);
  if (error) return calendarFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  const campId = editing ? result?.result_id : data;
  if (!isUuid(campId) || (editing && (campId !== fields.campId || !isUpdatedAt(result?.result_updated_at)))) {
    return calendarFailure("update-failed", fields);
  }
  revalidateCamp(campId);
  if (operation === "delete") redirect("/staff/camps?updated=deleted");
  redirect(`/staff/camps/${campId}${operation === "update" ? "?updated=saved" : ""}`);
}

export async function createStaffCamp(formData) {
  return runCampAction(formData, "create");
}

export async function updateStaffCamp(formData) {
  return runCampAction(formData, "update");
}

export async function deleteStaffCamp(formData) {
  return runCampAction(formData, "delete");
}

export async function addCampEligibleUsers(formData) {
  const { supabase } = await requireStaff("/staff/camps");
  const campId = getText(formData, "campId");

  if (!isUuid(campId)) {
    redirect(withQuery("/staff/camps", { error: "invalid-camp" }));
  }

  const pagePath = `/staff/camps/${campId}/eligible-users`;
  const submittedEmails = getText(formData, "eligibleEmails")
    .split(/[\s,;]+/)
    .filter(Boolean)
    .map((email) => email.toLowerCase());

  if (submittedEmails.length === 0) {
    redirect(withQuery(pagePath, { error: "required" }));
  }

  if (submittedEmails.length > 1000) {
    redirect(withQuery(pagePath, { error: "too-many-emails" }));
  }

  const invalidCount = submittedEmails.filter(
    (email) => !EMAIL_PATTERN.test(email),
  ).length;

  if (invalidCount > 0) {
    redirect(
      withQuery(pagePath, {
        error: "invalid-emails",
        invalidCount,
      }),
    );
  }

  const uniqueEmails = [...new Set(submittedEmails)];
  const duplicateCount = submittedEmails.length - uniqueEmails.length;
  const { data: registeredCount, error } = await supabase.rpc(
    "add_camp_eligible_users",
    {
      target_camp_id: campId,
      eligible_emails: uniqueEmails,
    },
  );

  if (error) {
    redirect(
      withQuery(pagePath, {
        error: calendarErrorCode(error),
      }),
    );
  }

  revalidatePath(pagePath);
  revalidatePath(`/staff/camps/${campId}`);
  redirect(
    withQuery(pagePath, {
      registered: registeredCount ?? uniqueEmails.length,
      duplicates: duplicateCount,
    }),
  );
}
