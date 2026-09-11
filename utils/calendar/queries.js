import "server-only";

import { createClient } from "@/utils/supabase/server";
import { requireStaff } from "@/utils/auth/guards";
import { isDate, isUuid } from "@/utils/calendar/validation";

function monthDate(month) {
  if (typeof month !== "string" || !/^\d{4}-\d{2}$/.test(month) || !isDate(`${month}-01`)) return null;
  return `${month}-01`;
}

function pick(row, keys) {
  return Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));
}

const STAFF_MONTH_COLUMNS = ["entry_type", "entry_id", "start_date", "end_date", "title", "people_count", "internal_reason", "updated_at"];
const STAFF_DAY_COLUMNS = ["entry_type", "entry_id", "camp_id", "reception_number", "display_name", "people_count", "status", "start_date", "end_date", "internal_reason", "updated_at"];
const BLOCK_COLUMNS = ["id", "start_date", "end_date", "internal_reason", "updated_at"];

// No shared cache: results depend on JST today and (for staff) current access.
// Reads never repair claims or advance any workflow.
export async function getPublicCalendar(month) {
  const targetMonth = monthDate(month);
  if (!targetMonth) return { error: "invalid-month", days: [] };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_public_calendar", { target_month: targetMonth });
  if (error || !Array.isArray(data)) return { error: "load-failed", days: [] };
  const expectedDays = Array.from({ length: 31 }, (_, index) => `${month}-${String(index + 1).padStart(2, "0")}`).filter(isDate);
  if (data.length !== expectedDays.length || data.some((day, index) => !day || day.date !== expectedDays[index]
    || !["available", "unavailable", "not_yet_open"].includes(day.availability))) {
    return { error: "load-failed", days: [] };
  }
  return { error: null, days: data.map((row) => pick(row, ["date", "availability"])) };
}

export async function getStaffCalendar(month) {
  const { supabase } = await requireStaff("/staff/calendar");
  const targetMonth = monthDate(month);
  if (!targetMonth) return { error: "invalid-month", entries: [] };
  const { data, error } = await supabase.rpc("get_staff_calendar", { target_month: targetMonth });
  if (error || !Array.isArray(data)) return { error: "load-failed", entries: [] };
  return { error: null, entries: data.map((row) => pick(row, STAFF_MONTH_COLUMNS)) };
}

export async function getStaffCalendarDay(date) {
  const { supabase } = await requireStaff("/staff/calendar");
  if (!isDate(date)) return { error: "invalid-period", entries: [] };
  const { data, error } = await supabase.rpc("get_staff_calendar_day", { target_date: date });
  if (error || !Array.isArray(data)) return { error: "load-failed", entries: [] };
  return { error: null, entries: data.map((row) => pick(row, STAFF_DAY_COLUMNS)) };
}

export async function getStaffBlockedPeriods(month) {
  const result = await getStaffCalendar(month);
  return { error: result.error, periods: result.entries.filter((entry) => entry.entry_type === "blocked") };
}

export async function getStaffBlockedPeriod(blockedPeriodId) {
  const { supabase } = await requireStaff("/staff/calendar/blocked-periods");
  if (!isUuid(blockedPeriodId)) return { error: "not-found", period: null };
  const { data, error } = await supabase.from("blocked_periods").select(BLOCK_COLUMNS.join(","))
    .eq("id", blockedPeriodId).is("deleted_at", null).maybeSingle();
  if (error) return { error: "load-failed", period: null };
  if (!data) return { error: "not-found", period: null };
  return { error: null, period: pick(data, BLOCK_COLUMNS) };
}
