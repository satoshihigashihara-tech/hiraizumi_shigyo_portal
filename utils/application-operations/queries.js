import "server-only";

import { requireActiveUser, requireStaff } from "@/utils/auth/guards";
import { isUuid, isUpdatedAt, isPaymentOverdue, paymentErrorCode, stayErrorCode, noteErrorCode,
  normalizeStaffApplicationSearch, staffSearchErrorCode, APPLICATION_STATUSES,
  STAFF_SEARCH_USAGE_TYPES, STAFF_SEARCH_PAYMENT_STATUSES, STAFF_SEARCH_STAY_STATUSES } from "@/utils/application-operations/validation";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));
async function readPayment(supabase, applicationId) {
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_application_payment", { target_application_id: applicationId });
  if (error) return { error: paymentErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (data?.id !== applicationId || !isUpdatedAt(data.updated_at)
    || !["camp", "community_individual"].includes(data.usage_type)) return { error: "load-failed", application: null };
  const application = pick(data, ["id", "usage_type", "camp_id", "status", "updated_at"]);
  application.charge = data.charge ? {
    ...pick(data.charge, ["total_amount", "payment_status", "payment_due_date", "paid_at"]),
    is_overdue: isPaymentOverdue(data.charge),
    months: (Array.isArray(data.charge.months) ? data.charge.months : [])
      .map((row) => pick(row, ["month", "usage_days", "daily_rate", "monthly_cap", "amount"])),
  } : null;
  return { error: null, application };
}

export async function getApplicationPayment(applicationId) {
  const { supabase } = await requireActiveUser("/user/applications");
  return readPayment(supabase, applicationId);
}

export async function getStaffApplicationPayment(applicationId) {
  const { supabase } = await requireStaff("/staff");
  return readPayment(supabase, applicationId);
}

async function readStay(supabase, applicationId) {
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_application_stay", { target_application_id: applicationId });
  if (error) return { error: stayErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (data?.id !== applicationId || !isUpdatedAt(data.updated_at)
    || !["camp", "community_individual"].includes(data.usage_type)) return { error: "load-failed", application: null };
  return { error: null, application: {
    ...pick(data, ["id", "usage_type", "camp_id", "status", "updated_at", "start_date", "end_date"]),
    stay: data.stay ? pick(data.stay, ["status", "checked_in_at", "checked_out_at"]) : null,
    room_allocation: data.room_allocation ? pick(data.room_allocation,
      ["room_id", "room_name", "people_count", "start_date", "end_date", "released_from", "is_current"]) : null,
  } };
}

export async function getApplicationStay(applicationId) {
  const { supabase } = await requireActiveUser("/user/applications");
  return readStay(supabase, applicationId);
}

export async function getStaffApplicationStay(applicationId) {
  const { supabase } = await requireStaff("/staff");
  return readStay(supabase, applicationId);
}

export async function getStaffApplicationNotes(applicationId) {
  const { supabase } = await requireStaff("/staff");
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_staff_application_notes", { target_application_id: applicationId });
  if (error) return { error: noteErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (data?.id !== applicationId || !isUpdatedAt(data.updated_at) || !Array.isArray(data.notes)) return { error: "load-failed", application: null };
  return { error: null, application: { ...pick(data, ["id", "usage_type", "camp_id", "updated_at"]),
    notes: data.notes.map((note) => pick(note, ["id", "body", "author_user_id", "created_at", "updated_at"])),
  } };
}

const nullableString = (value) => value === null || typeof value === "string";
const nullableDate = (value) => value === null || (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value));
const validSearchItem = (item) => {
  if (!item || !isUuid(item.id) || !STAFF_SEARCH_USAGE_TYPES.includes(item.usage_type)
    || !APPLICATION_STATUSES.includes(item.status) || !isUpdatedAt(item.updated_at)
    || !nullableString(item.applicant_name) || !nullableString(item.camp_name)
    || !nullableString(item.reception_number) || !nullableDate(item.start_date) || !nullableDate(item.end_date)
    || item.people_count !== 1 || (item.total_amount !== null && (!Number.isInteger(item.total_amount) || item.total_amount < 0))
    || (item.payment_status !== null && !STAFF_SEARCH_PAYMENT_STATUSES.includes(item.payment_status))
    || !nullableDate(item.payment_due_date)
    || (item.stay_status !== null && !STAFF_SEARCH_STAY_STATUSES.includes(item.stay_status))) return false;
  const expectedPath = item.usage_type === "camp"
    ? (isUuid(item.camp_id) ? `/staff/camps/${item.camp_id}/applications/${item.id}` : null)
    : `/staff/community/applications/${item.id}`;
  if ((item.usage_type === "camp" && !isUuid(item.camp_id))
    || (item.usage_type === "community_individual" && item.camp_id !== null)) return false;
  return item.detail_path === expectedPath;
};

export async function searchStaffApplications(searchParams = {}) {
  const { supabase } = await requireStaff("/staff");
  const normalized = normalizeStaffApplicationSearch(searchParams);
  const empty = { error: normalized.error, filters: normalized.filters, applications: [],
    pagination: { page: Number(normalized.filters.page) || 1, pageSize: 50, totalCount: 0, hasNext: false } };
  if (normalized.error) return empty;
  const { filters } = normalized;
  const { data, error } = await supabase.rpc("search_staff_applications", {
    search_text: filters.q || null,
    usage_type_filter: filters.usageType || null,
    application_status_filter: filters.applicationStatus || null,
    payment_status_filter: filters.paymentStatus || null,
    stay_status_filter: filters.stayStatus || null,
    starts_from: filters.from || null,
    ends_to: filters.to || null,
    page_number: filters.page,
  });
  if (error) return { ...empty, error: staffSearchErrorCode(error) };
  if (!data || data.page !== filters.page || data.page_size !== 50
    || !Number.isInteger(data.total_count) || data.total_count < 0 || typeof data.has_next !== "boolean"
    || !Array.isArray(data.items) || data.items.length > 50 || !data.items.every(validSearchItem)) {
    return { ...empty, error: "load-failed" };
  }
  const keys = ["id", "usage_type", "camp_id", "applicant_name", "camp_name", "status", "start_date", "end_date",
    "reception_number", "people_count", "total_amount", "payment_status", "payment_due_date", "stay_status", "updated_at", "detail_path"];
  return { error: null, filters, applications: data.items.map((item) => pick(item, keys)),
    pagination: { page: data.page, pageSize: data.page_size, totalCount: data.total_count, hasNext: data.has_next } };
}
