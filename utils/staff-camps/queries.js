import "server-only";

import { requireStaff } from "@/utils/auth/guards";
import { isDate, isUuid } from "@/utils/calendar/validation";

const CAMP_COLUMNS = "id,name,start_date,end_date,application_deadline,created_at,updated_at";
const ELIGIBLE_COLUMNS = "id,email_normalized,created_at,updated_at";

function isTimestamp(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function validCamp(row) {
  return row && isUuid(row.id) && typeof row.name === "string" && row.name.trim() !== ""
    && isDate(row.start_date) && isDate(row.end_date)
    && isTimestamp(row.application_deadline) && isTimestamp(row.created_at)
    && isTimestamp(row.updated_at);
}

export async function getStaffCamps() {
  const { supabase } = await requireStaff("/staff/camps");
  const { data, error } = await supabase.from("camps").select(CAMP_COLUMNS)
    .is("deleted_at", null).order("start_date", { ascending: false }).limit(100);
  if (error || !Array.isArray(data) || data.some((row) => !validCamp(row))) {
    return { error: "load-failed", camps: [] };
  }
  return { error: null, camps: data };
}

export async function getStaffCamp(campId) {
  const { supabase } = await requireStaff("/staff/camps");
  if (!isUuid(campId)) return { error: "not-found", camp: null };
  const [campResult, eligibleResult, applicationsResult] = await Promise.all([
    supabase.from("camps").select(CAMP_COLUMNS).eq("id", campId).is("deleted_at", null).maybeSingle(),
    supabase.from("camp_eligible_users").select("id", { count: "exact", head: true })
      .eq("camp_id", campId).is("disabled_at", null),
    supabase.from("applications").select("id", { count: "exact", head: true }).eq("camp_id", campId),
  ]);
  if (campResult.error || eligibleResult.error || applicationsResult.error) {
    return { error: "load-failed", camp: null };
  }
  if (!campResult.data) return { error: "not-found", camp: null };
  if (!validCamp(campResult.data)
    || !Number.isSafeInteger(eligibleResult.count) || eligibleResult.count < 0
    || !Number.isSafeInteger(applicationsResult.count) || applicationsResult.count < 0) {
    return { error: "load-failed", camp: null };
  }
  return { error: null, camp: {
    ...campResult.data,
    eligible_count: eligibleResult.count,
    application_count: applicationsResult.count,
  } };
}

export async function getCampEligibleUsers(campId) {
  const { supabase } = await requireStaff("/staff/camps");
  if (!isUuid(campId)) return { error: "not-found", users: [] };
  const { data, error } = await supabase.from("camp_eligible_users").select(ELIGIBLE_COLUMNS)
    .eq("camp_id", campId).is("disabled_at", null).order("email_normalized").limit(1000);
  if (error || !Array.isArray(data) || data.some((row) => !row || !isUuid(row.id)
    || typeof row.email_normalized !== "string" || row.email_normalized === ""
    || !isTimestamp(row.created_at) || !isTimestamp(row.updated_at))) {
    return { error: "load-failed", users: [] };
  }
  return { error: null, users: data };
}
