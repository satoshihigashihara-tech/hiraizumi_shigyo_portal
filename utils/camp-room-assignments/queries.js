import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";
import { isUuid } from "@/utils/application-operations/validation";

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const MODES = ["eligible_roster", "legacy_application"];
const PARTICIPATION_STATES = ["participating", "ended", "legacy"];
const PLACEMENT_STATES = ["assigned", "unassigned", "ended", "legacy"];

function nullableUuid(value) {
  return value === null || isUuid(value);
}

function nullableDate(value) {
  return value === null || (typeof value === "string" && DATE.test(value));
}

function validRow(row) {
  if (!row || !isUuid(row.camp_id) || !nullableUuid(row.application_id)
    || typeof row.camp_name !== "string" || row.camp_name.trim() === ""
    || !DATE.test(row.start_date ?? "") || !DATE.test(row.end_date ?? "")
    || row.start_date > row.end_date || !MODES.includes(row.room_assignment_mode)
    || !PARTICIPATION_STATES.includes(row.participation_state)
    || !PLACEMENT_STATES.includes(row.placement_state)
    || !nullableDate(row.assignment_start_date) || !nullableDate(row.assignment_end_date)
    || (row.floor !== null && (!Number.isSafeInteger(row.floor) || row.floor < 1))
    || (row.room_name !== null && (typeof row.room_name !== "string" || row.room_name.trim() === ""))) return false;

  if (row.room_assignment_mode === "legacy_application") {
    return row.participation_state === "legacy" && row.placement_state === "legacy"
      && row.room_name === null && row.floor === null
      && row.assignment_start_date === null && row.assignment_end_date === null;
  }
  if (row.participation_state === "legacy" || row.placement_state === "legacy") return false;
  if (row.placement_state === "assigned") {
    return row.participation_state === "participating" && row.room_name !== null
      && row.floor !== null && row.assignment_start_date !== null
      && row.assignment_end_date !== null && row.assignment_start_date <= row.assignment_end_date;
  }
  return row.room_name === null && row.floor === null
    && row.assignment_start_date === null && row.assignment_end_date === null;
}

function pick(row) {
  return {
    campId: row.camp_id,
    campName: row.camp_name,
    startDate: row.start_date,
    endDate: row.end_date,
    mode: row.room_assignment_mode,
    applicationId: row.application_id,
    participationState: row.participation_state,
    placementState: row.placement_state,
    roomName: row.room_name,
    floor: row.floor,
    assignmentStartDate: row.assignment_start_date,
    assignmentEndDate: row.assignment_end_date,
  };
}

export async function getMyCampRoomAssignments(returnTo = "/user/camp-room") {
  const { supabase } = await requireActiveUser(returnTo);
  const { data, error } = await supabase.rpc("get_my_camp_room_assignments");
  if (error || !Array.isArray(data) || data.length > 100 || data.some((row) => !validRow(row))) {
    return { error: "load-failed", assignments: [] };
  }
  return { error: null, assignments: data.map(pick) };
}
