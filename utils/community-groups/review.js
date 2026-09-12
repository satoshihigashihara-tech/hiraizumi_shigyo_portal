import "server-only";

import { getText, toTokyoDeadline } from "@/utils/calendar/validation";
import { groupErrorCode, isUpdatedAt, isUuid } from "@/utils/community-groups/validation";

export function readGroupReviewFields(formData) {
  return Object.fromEntries(["groupId", "applicationId", "updatedAt", "reason", "revisionDeadline", "roomPlan", "confirmed"]
    .map((key) => [key, getText(formData, key)]));
}

export function validateReason(value, required = false) {
  const reason = value.trim();
  if (required && !reason) return "reason-required";
  if (Array.from(reason).length > 2000) return "reason-too-long";
  return null;
}

export function parseRoomPlan(value, allowEmpty = false) {
  let parsed;
  try { parsed = JSON.parse(value); } catch { return null; }
  if (!Array.isArray(parsed) || (!allowEmpty && !parsed.length) || parsed.length > 8) return null;
  if (parsed.some((item) => !item || typeof item !== "object" || !isUuid(item.roomId)
    || !Number.isInteger(Number(item.peopleCount)) || Number(item.peopleCount) < 1 || Number(item.peopleCount) > 3)) return null;
  if (new Set(parsed.map((item) => item.roomId)).size !== parsed.length) return null;
  return parsed.map((item) => ({ room_id: item.roomId, people_count: Number(item.peopleCount) }));
}

export function reviewFailure(error, fields = {}) {
  const code = groupErrorCode(error);
  const field = {
    "reason-required": "reason",
    "reason-too-long": "reason",
    "invalid-deadline": "revisionDeadline",
    "invalid-room-plan": "roomPlan",
    "duplicate-room": "roomPlan",
    "room-required": "roomPlan",
    "room-capacity-full": "roomPlan",
    "allocation-count-mismatch": "roomPlan",
    "confirmation-required": "confirmed",
  }[code];
  return { error: code, fields, fieldErrors: field ? { [field]: code } : {} };
}

export function validateReviewIdentity(fields, participant = false) {
  if (!isUuid(fields.groupId)) return "invalid-group";
  if (participant && !isUuid(fields.applicationId)) return "invalid-application";
  if (!isUpdatedAt(fields.updatedAt)) return "invalid-version";
  return null;
}

export function revisionDeadline(value) { return value ? toTokyoDeadline(value) : null; }
