"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const DATETIME_LOCAL_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

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

function staffDatabaseErrorCode(error) {
  const message = error?.message ?? "";

  if (message.includes("職員")) return "forbidden";
  if (message.includes("重複")) return "date-conflict";
  if (message.includes("見つかりません")) return "not-found";
  if (message.includes("メールアドレス")) return "invalid-emails";
  if (message.includes("1000件")) return "too-many-emails";
  if (message.includes("キャンプ名")) return "invalid-name";
  if (message.includes("期間") || message.includes("開始日")) {
    return "invalid-period";
  }

  return "unexpected";
}

function toTokyoTimestamp(value) {
  if (!DATETIME_LOCAL_PATTERN.test(value)) {
    return null;
  }

  const date = new Date(`${value}:00+09:00`);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

async function getStaffClient(returnTo) {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    redirect(withQuery("/login", { returnTo }));
  }

  const { data: staffRole, error: roleError } = await supabase
    .from("staff_roles")
    .select("user_id")
    .eq("user_id", user.id)
    .maybeSingle();

  if (roleError || !staffRole) {
    redirect("/forbidden");
  }

  return supabase;
}

export async function createStaffCamp(formData) {
  const formPath = "/staff/camps/new";
  const name = getText(formData, "campName");
  const startDate = getText(formData, "startDate");
  const endDate = getText(formData, "endDate");
  const deadline = toTokyoTimestamp(
    getText(formData, "applicationDeadline"),
  );

  if (
    !name ||
    !DATE_PATTERN.test(startDate) ||
    !DATE_PATTERN.test(endDate) ||
    !deadline
  ) {
    redirect(withQuery(formPath, { error: "required" }));
  }

  const supabase = await getStaffClient(formPath);
  const { data: campId, error } = await supabase.rpc("create_staff_camp", {
    camp_name: name,
    camp_start_date: startDate,
    camp_end_date: endDate,
    camp_application_deadline: deadline,
  });

  if (error || !UUID_PATTERN.test(campId ?? "")) {
    redirect(
      withQuery(formPath, {
        error: staffDatabaseErrorCode(error),
      }),
    );
  }

  revalidatePath("/staff/camps");
  redirect(`/staff/camps/${campId}`);
}

export async function addCampEligibleUsers(formData) {
  const campId = getText(formData, "campId");

  if (!UUID_PATTERN.test(campId)) {
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
  const supabase = await getStaffClient(pagePath);
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
        error: staffDatabaseErrorCode(error),
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
