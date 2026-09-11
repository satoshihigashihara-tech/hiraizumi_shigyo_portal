import { isDate } from "@/utils/calendar/validation";

const MONTH = /^\d{4}-\d{2}$/;

export function currentJstMonth(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
  }).formatToParts(now);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}`;
}

export function normalizeCalendarMonth(value, fallback = currentJstMonth()) {
  const candidate = Array.isArray(value) ? value[0] : value;
  return typeof candidate === "string" && MONTH.test(candidate) && isDate(`${candidate}-01`)
    ? candidate
    : fallback;
}

export function shiftCalendarMonth(month, amount) {
  const [year, monthNumber] = month.split("-").map(Number);
  const index = Math.max(12, year * 12 + monthNumber - 1 + amount);
  const nextYear = Math.floor(index / 12);
  const nextMonth = index - nextYear * 12 + 1;
  return `${String(nextYear).padStart(4, "0")}-${String(nextMonth).padStart(2, "0")}`;
}

export function calendarMonthLabel(month) {
  const [year, monthNumber] = month.split("-");
  return `${Number(year)}年${Number(monthNumber)}月`;
}

export function firstWeekday(month) {
  const [year, monthNumber] = month.split("-").map(Number);
  return new Date(Date.UTC(year, monthNumber - 1, 1)).getUTCDay();
}
