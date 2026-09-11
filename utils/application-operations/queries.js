import "server-only";

import { requireActiveUser, requireStaff } from "@/utils/auth/guards";
import { readApplicationPayment, readApplicationStay,
  isUuid, isUpdatedAt, noteErrorCode,
  normalizeStaffApplicationSearch, staffSearchErrorCode, APPLICATION_STATUSES,
  STAFF_SEARCH_USAGE_TYPES, STAFF_SEARCH_PAYMENT_STATUSES, STAFF_SEARCH_STAY_STATUSES } from "@/utils/application-operations/readers";

const pick = (row, keys) => Object.fromEntries(keys.map((key) => [key, row[key] ?? null]));

export async function getApplicationPayment(applicationId) {
  const { supabase } = await requireActiveUser("/user/applications");
  return readApplicationPayment(supabase, applicationId);
}

export async function getStaffApplicationPayment(applicationId) {
  const { supabase } = await requireStaff("/staff");
  return readApplicationPayment(supabase, applicationId);
}

export async function getApplicationStay(applicationId) {
  const { supabase } = await requireActiveUser("/user/applications");
  return readApplicationStay(supabase, applicationId);
}

export async function getStaffApplicationStay(applicationId) {
  const { supabase } = await requireStaff("/staff");
  return readApplicationStay(supabase, applicationId);
}

export async function getStaffApplicationNotes(applicationId) {
  const { supabase } = await requireStaff("/staff");
  if (!isUuid(applicationId)) return { error: "not-found", application: null };
  const { data, error } = await supabase.rpc("get_staff_application_notes", { target_application_id: applicationId });
  if (error) return { error: noteErrorCode(error) === "not-found" ? "not-found" : "load-failed", application: null };
  if (data?.id !== applicationId || !isUpdatedAt(data.updated_at) || !Array.isArray(data.notes)) return { error: "load-failed", application: null };
  return { error: null, application: { ...pick(data, ["id", "usage_type", "camp_id", "original_application_id", "updated_at"]),
    notes: data.notes.map((note) => pick(note, ["id", "body", "author_user_id", "created_at", "updated_at"])),
  } };
}

const nullableString = (value) => value === null || typeof value === "string";
const nullableDate = (value) => value === null || (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value));
const validSearchItem = (item) => {
  if (!item || !isUuid(item.id) || !STAFF_SEARCH_USAGE_TYPES.includes(item.usage_type)
    || !APPLICATION_STATUSES.includes(item.status) || !isUpdatedAt(item.updated_at)
    || (item.original_application_id != null && !isUuid(item.original_application_id))
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
  const keys = ["id", "usage_type", "camp_id", "original_application_id", "applicant_name", "camp_name", "status", "start_date", "end_date",
    "reception_number", "people_count", "total_amount", "payment_status", "payment_due_date", "stay_status", "updated_at", "detail_path"];
  return { error: null, filters, applications: data.items.map((item) => pick(item, keys)),
    pagination: { page: data.page, pageSize: data.page_size, totalCount: data.total_count, hasNext: data.has_next } };
}

const CAMP_DETAIL_FIELDS = [
  "id", "camp_id", "usage_type", "status", "start_date", "end_date",
  "user_name", "user_address", "user_phone", "email_snapshot",
  "emergency_name", "emergency_address", "emergency_phone", "usage_place",
  "purpose", "local_activity", "special_notes", "requires_guardian_consent",
  "room_preference", "submitted_at", "last_submitted_at", "revision_due_at",
  "decision_reason", "approval_comment", "updated_at",
];

const validStatusEvent = (row) => row
  && (row.from_status === null || APPLICATION_STATUSES.includes(row.from_status))
  && APPLICATION_STATUSES.includes(row.to_status)
  && nullableString(row.public_reason)
  && isUpdatedAt(row.occurred_at);

const CAMP_DETAIL_TEXT_FIELDS = [
  "user_name", "user_address", "user_phone", "email_snapshot", "emergency_name",
  "emergency_address", "emergency_phone", "usage_place", "purpose", "local_activity",
  "special_notes", "room_preference", "start_date", "end_date", "submitted_at",
  "last_submitted_at", "revision_due_at", "decision_reason", "approval_comment",
];

const validStaffNote = (note) => note && isUuid(note.id)
  && typeof note.body === "string"
  && (note.author_user_id === null || isUuid(note.author_user_id))
  && isUpdatedAt(note.created_at) && isUpdatedAt(note.updated_at);

/** Staff-only, allowlisted snapshot for the camp review screen. */
export async function getStaffCampApplicationDetail(campId, applicationId) {
  const returnTo = isUuid(campId) && isUuid(applicationId)
    ? `/staff/camps/${campId}/applications/${applicationId}`
    : "/staff";
  const { supabase } = await requireStaff(returnTo);
  if (!isUuid(campId) || !isUuid(applicationId)) {
    return { error: "not-found", application: null, rooms: [] };
  }

  const [applicationResult, payment, stay, notesResult, historyResult,
    roomsResult, receptionResult, campResult, consentResult] = await Promise.all([
    supabase.from("applications").select(CAMP_DETAIL_FIELDS.join(","))
      .eq("id", applicationId).eq("camp_id", campId).eq("usage_type", "camp").maybeSingle(),
    readApplicationPayment(supabase, applicationId),
    readApplicationStay(supabase, applicationId),
    supabase.rpc("get_staff_application_notes", { target_application_id: applicationId }),
    supabase.from("application_status_events").select("from_status,to_status,public_reason,occurred_at")
      .eq("application_id", applicationId).order("occurred_at", { ascending: false }),
    supabase.from("rooms").select("id,name,capacity").order("name", { ascending: true }),
    supabase.from("reception_numbers").select("display_number").eq("application_id", applicationId).maybeSingle(),
    supabase.from("camps").select("id,name,start_date,end_date").eq("id", campId).maybeSingle(),
    supabase.from("consent_documents").select("id").eq("application_id", applicationId).maybeSingle(),
  ]);

  const row = applicationResult.data;
  if (applicationResult.error || !row) {
    return { error: applicationResult.error ? "load-failed" : "not-found", application: null, rooms: [] };
  }
  const relatedError = payment.error || stay.error || notesResult.error || historyResult.error
    || roomsResult.error || receptionResult.error || campResult.error || consentResult.error;
  const notes = notesResult.data;
  if (relatedError || !campResult.data || campResult.data.id !== campId
    || row.id !== applicationId || row.camp_id !== campId || row.usage_type !== "camp"
    || !APPLICATION_STATUSES.includes(row.status) || !isUpdatedAt(row.updated_at)
    || !CAMP_DETAIL_TEXT_FIELDS.every((field) => nullableString(row[field]))
    || (row.requires_guardian_consent !== null && typeof row.requires_guardian_consent !== "boolean")
    || payment.application?.id !== applicationId || payment.application?.usage_type !== "camp"
    || payment.application?.camp_id !== campId || payment.application.updated_at !== row.updated_at
    || stay.application?.id !== applicationId || stay.application?.usage_type !== "camp"
    || stay.application?.camp_id !== campId || stay.application.updated_at !== row.updated_at
    || notes?.id !== applicationId || notes?.usage_type !== "camp" || notes?.camp_id !== campId
    || notes.updated_at !== row.updated_at || !Array.isArray(notes.notes)
    || !notes.notes.every(validStaffNote)
    || !Array.isArray(historyResult.data) || !historyResult.data.every(validStatusEvent)
    || (receptionResult.data !== null && typeof receptionResult.data?.display_number !== "string")
    || (consentResult.data !== null && !isUuid(consentResult.data?.id))
    || !Array.isArray(roomsResult.data)
    || !roomsResult.data.every((room) => isUuid(room.id) && typeof room.name === "string"
      && Number.isInteger(room.capacity) && room.capacity > 0)) {
    return { error: "load-failed", application: null, rooms: [] };
  }

  return {
    error: null,
    rooms: roomsResult.data.map((room) => pick(room, ["id", "name", "capacity"])),
    application: {
      ...pick(row, CAMP_DETAIL_FIELDS),
      camp_name: campResult.data.name,
      reception_number: receptionResult.data?.display_number ?? null,
      has_consent: Boolean(consentResult.data),
      charge: payment.application.charge,
      stay: stay.application.stay,
      room_allocation: stay.application.room_allocation?.is_current === true
        ? stay.application.room_allocation : null,
      events: historyResult.data.map((event) => pick(event,
        ["from_status", "to_status", "public_reason", "occurred_at"])),
      notes: notes.notes.map((note) => pick(note,
        ["id", "body", "author_user_id", "created_at", "updated_at"])),
    },
  };
}
