import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";
import { isPaymentOverdue, isUpdatedAt, isUuid } from "@/utils/application-operations/validation";

const STATUSES = ["draft", "submitted", "under_review", "revision_requested", "approved", "rejected", "cancellation_requested", "cancelled"];
const USAGE_TYPES = ["camp", "community_individual", "community_group"];
const STAY_STATUSES = ["before_move_in", "staying", "moved_out"];
const DATE = /^\d{4}-\d{2}-\d{2}$/;

function nullableText(value) { return value === null || typeof value === "string"; }
function nullableDate(value) { return value === null || (typeof value === "string" && DATE.test(value)); }
function nullableTimestamp(value) { return value === null || isUpdatedAt(value); }
function one(value) { return Array.isArray(value) ? (value.length === 1 ? value[0] : null) : value; }
function validRelation(value) { return value === null || (typeof value === "object" && !Array.isArray(value)); }

function normalize(row) {
  const camp = one(row.camps);
  const reception = one(row.reception_numbers);
  const charge = one(row.application_charges);
  const allocation = one(row.room_allocations);
  const stay = one(row.stays);
  const room = allocation ? one(allocation.rooms) : null;
  if (!isUuid(row.id) || (row.original_application_id !== null && !isUuid(row.original_application_id))
    || !USAGE_TYPES.includes(row.usage_type) || !STATUSES.includes(row.status)
    || !nullableDate(row.start_date) || !nullableDate(row.end_date) || !isUpdatedAt(row.updated_at)
    || (row.start_date !== null && row.end_date !== null && row.start_date > row.end_date)
    || !nullableTimestamp(row.submitted_at) || !nullableTimestamp(row.last_submitted_at)
    || !nullableTimestamp(row.revision_due_at) || !nullableText(row.decision_reason)
    || !validRelation(camp) || !validRelation(reception) || !validRelation(charge)
    || !validRelation(allocation) || !validRelation(stay) || !validRelation(room)) return null;
  if ((row.usage_type === "camp" && (!camp || typeof camp.name !== "string" || camp.name.trim() === ""))
    || (camp && typeof camp.name !== "string")) return null;
  if (reception && (typeof reception.display_number !== "string" || !/^SG-\d{4}-\d+$/.test(reception.display_number))) return null;
  if (charge && (!Number.isSafeInteger(charge.total_amount) || charge.total_amount < 0
    || !["unpaid", "paid"].includes(charge.payment_status) || !nullableDate(charge.payment_due_date)
    || !nullableTimestamp(charge.paid_at))) return null;
  if (allocation && (!isUuid(allocation.room_id) || !Number.isSafeInteger(allocation.people_count)
    || !nullableDate(allocation.start_date) || !nullableDate(allocation.end_date)
    || !nullableDate(allocation.released_from) || !room || typeof room.name !== "string")) return null;
  if (stay && (!STAY_STATUSES.includes(stay.status) || !nullableTimestamp(stay.checked_in_at)
    || !nullableTimestamp(stay.checked_out_at))) return null;
  return {
    id: row.id, usage_type: row.usage_type, original_application_id: row.original_application_id,
    status: row.status, start_date: row.start_date, end_date: row.end_date,
    updated_at: row.updated_at, submitted_at: row.submitted_at,
    last_submitted_at: row.last_submitted_at, revision_due_at: row.revision_due_at,
    decision_reason: row.decision_reason, camp_name: camp?.name ?? null,
    reception_number: reception?.display_number ?? null,
    charge: charge ? { total_amount: charge.total_amount, payment_status: charge.payment_status,
      payment_due_date: charge.payment_due_date, paid_at: charge.paid_at,
      is_overdue: isPaymentOverdue(charge) } : null,
    room: allocation && room ? { name: room.name, people_count: allocation.people_count,
      start_date: allocation.start_date, end_date: allocation.end_date,
      released_from: allocation.released_from } : null,
    stay: stay ? { status: stay.status, checked_in_at: stay.checked_in_at,
      checked_out_at: stay.checked_out_at } : null,
    detail_path: row.usage_type === "camp" ? `/user/applications/${row.id}` : null,
  };
}

export async function getUserApplications() {
  const { supabase, user } = await requireActiveUser("/user/applications");
  const { data, error } = await supabase.from("applications").select(`
    id,usage_type,original_application_id,status,start_date,end_date,updated_at,submitted_at,
    last_submitted_at,revision_due_at,decision_reason,camps(name),reception_numbers(display_number),
    application_charges(total_amount,payment_status,payment_due_date,paid_at),
    room_allocations(room_id,people_count,start_date,end_date,released_from,rooms(name)),
    stays(status,checked_in_at,checked_out_at)
  `).eq("user_id", user.id).order("created_at", { ascending: false }).order("id", { ascending: false }).limit(100);
  if (error || !Array.isArray(data)) return { error: "load-failed", applications: [] };
  const applications = data.map(normalize);
  if (applications.some((row) => row === null)) return { error: "load-failed", applications: [] };
  return { error: null, applications };
}
