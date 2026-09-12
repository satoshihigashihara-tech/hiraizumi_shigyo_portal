import "server-only";

import { requireStaff } from "@/utils/auth/guards";
import { isDate, isUuid } from "@/utils/calendar/validation";

const CAMP_COLUMNS = "id,name,start_date,end_date,application_deadline,room_assignment_mode,created_at,updated_at";
const ELIGIBLE_COLUMNS = "id,email_normalized,disabled_at,created_at,updated_at";

function isTimestamp(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function validCamp(row) {
  return row && isUuid(row.id) && typeof row.name === "string" && row.name.trim() !== ""
    && isDate(row.start_date) && isDate(row.end_date)
    && ["legacy_application", "eligible_roster"].includes(row.room_assignment_mode)
    && isTimestamp(row.application_deadline) && isTimestamp(row.created_at)
    && isTimestamp(row.updated_at);
}

function validRosterUser(row) {
  return row && isUuid(row.id) && (row.management_name === null || typeof row.management_name === "string")
    && typeof row.email_normalized === "string" && row.email_normalized !== "" && isTimestamp(row.updated_at)
    && (row.disabled_at === null || isTimestamp(row.disabled_at))
    && ["participating", "released"].includes(row.participation_status)
    && (row.released_at === null || isTimestamp(row.released_at))
    && (row.application_id === null || isUuid(row.application_id))
    && (row.application_status === null || typeof row.application_status === "string")
    && (row.linked_user_id === null || isUuid(row.linked_user_id));
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
    .eq("camp_id", campId).order("email_normalized").limit(1000);
  if (error || !Array.isArray(data) || data.some((row) => !row || !isUuid(row.id)
    || typeof row.email_normalized !== "string" || row.email_normalized === ""
    || (row.disabled_at !== null && !isTimestamp(row.disabled_at))
    || !isTimestamp(row.created_at) || !isTimestamp(row.updated_at))) {
    return { error: "load-failed", users: [] };
  }
  return { error: null, users: data };
}

export async function getCampEligibleRoster(campId) {
  const { supabase } = await requireStaff("/staff/camps");
  if (!isUuid(campId)) return { error: "not-found", roster: null, users: [] };
  const { data, error } = await supabase.rpc("get_staff_camp_roster", { target_camp_id: campId });
  if (error || !data || data.camp_id !== campId || data.room_assignment_mode !== "eligible_roster"
    || !Array.isArray(data.eligible_users) || data.eligible_users.some((row) => !validRosterUser(row))) {
    return { error: error?.message === "not-found" ? "not-found" : "load-failed", roster: null, users: [] };
  }
  return {
    error: null,
    roster: {
      campId: data.camp_id,
      rosterVersion: data.roster_version,
      rosterLabelVersion: data.roster_label_version,
    },
    // Never pass linked UUIDs, linked emails, release reasons, or application IDs to the client form.
    users: data.eligible_users.map((row) => ({
      id: row.id, management_name: row.management_name, email_normalized: row.email_normalized,
      updated_at: row.updated_at, disabled_at: row.disabled_at, participation_status: row.participation_status,
      is_linked: row.linked_user_id !== null, has_application: row.application_id !== null,
      application_status: row.application_status,
    })),
  };
}
