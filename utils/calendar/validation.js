// Shared input/output contract for T09. No credentials or database access here.
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const VERSION_PATTERN = /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-](?:0\d|1[0-5]):[0-5]\d)$/;
const ERROR_CODES = new Set([
  "invalid-period", "invalid-month", "invalid-name", "invalid-deadline",
  "invalid-version", "stale-update", "invalid-status", "reason-required", "reason-too-long",
  "not-found", "date-conflict", "camp-has-applications", "calendar-inconsistent", "calendar-unavailable",
  "confirmation-required",
  "invalid-email", "eligible-email-exists", "eligible-has-application",
]);

export function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export function isUuid(value) {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function isDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year > 0 && month >= 1 && month <= 12 && day >= 1 && day <= days[month - 1];
}

export function isUpdatedAt(value) {
  return typeof value === "string" && VERSION_PATTERN.test(value)
    && isDate(value.slice(0, 10)) && Number.isFinite(Date.parse(value));
}

export function toTokyoDeadline(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$/.test(value)
    || !isDate(value.slice(0, 10))) return null;
  // A displayed minute is inclusive: 23:59 is stored as next day's 00:00.
  return new Date(Date.parse(`${value}:00+09:00`) + 60_000).toISOString();
}

export function periodError(startDate, endDate) {
  return !isDate(startDate) || !isDate(endDate) || startDate > endDate ? "invalid-period" : null;
}

export function reasonError(reason, required = true) {
  if (required && !reason) return "reason-required";
  return Array.from(reason).length > 2000 ? "reason-too-long" : null;
}

export function calendarErrorCode(error) {
  const message = error?.message ?? "";
  if (error?.code === "42501" || message === "staff-required" || message.includes("職員")) return "forbidden";
  if (error?.code === "40001" || error?.code === "40P01") return "stale-update";
  if (ERROR_CODES.has(message)) return message;
  if (message.includes("重複")) return "date-conflict";
  if (message.includes("見つかりません")) return "not-found";
  if (message.includes("メールアドレス")) return "invalid-emails";
  if (message.includes("1000件")) return "too-many-emails";
  if (message.includes("キャンプ名")) return "invalid-name";
  if (message.includes("期間") || message.includes("開始日")) return "invalid-period";
  return "update-failed";
}

// Use ONLY after requireStaff. Whitelist diagnostics instead of exposing SQL errors.
export function calendarFailure(error, fields = {}, fieldErrors = {}) {
  const code = typeof error === "string" ? error : calendarErrorCode(error);
  const conflicts = [];
  if (code === "date-conflict" || code === "camp-has-applications") {
    let parsed;
    try { parsed = JSON.parse(error?.details ?? "[]"); } catch { parsed = []; }
    if (Array.isArray(parsed)) {
      for (const item of parsed.slice(0, 100)) {
        if (!item || !["camp", "blocked", "application", "group"].includes(item.type) || !isUuid(item.id)
          || !isDate(item.startDate) || !isDate(item.endDate)) continue;
        conflicts.push({
          type: item.type, id: item.id, campId: isUuid(item.campId) ? item.campId : null,
          name: typeof item.name === "string" ? item.name : null,
          receptionNumber: typeof item.receptionNumber === "string" ? item.receptionNumber : null,
          status: typeof item.status === "string" ? item.status : null,
          startDate: item.startDate, endDate: item.endDate,
        });
      }
    }
  }
  return { error: code, fields, fieldErrors, conflicts };
}
