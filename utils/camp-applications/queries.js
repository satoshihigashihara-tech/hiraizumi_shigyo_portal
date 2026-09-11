import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";

const CAMP_ENTRY_PATH = "/user/applications/new/camp";
const CAMP_COLUMNS = [
  "id",
  "name",
  "start_date",
  "end_date",
  "application_deadline",
];
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function isValidDate(value) {
  if (typeof value !== "string" || !DATE_PATTERN.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

function isCamp(row) {
  return (
    row &&
    UUID_PATTERN.test(row.id ?? "") &&
    typeof row.name === "string" &&
    row.name.trim() !== "" &&
    isValidDate(row.start_date) &&
    isValidDate(row.end_date) &&
    row.start_date <= row.end_date &&
    typeof row.application_deadline === "string" &&
    Number.isFinite(Date.parse(row.application_deadline))
  );
}

function pickCamp(row) {
  return Object.fromEntries(
    CAMP_COLUMNS.map((column) => [column, row[column] ?? null]),
  );
}

/**
 * ログイン中の対象メールに紐づくキャンプだけを取得する。
 * camps のRLSが対象メール・削除状態を判定するため、画面へメールや対象者一覧を渡さない。
 */
export async function getEligibleCamps() {
  const { supabase } = await requireActiveUser(CAMP_ENTRY_PATH);
  const { data, error } = await supabase
    .from("camps")
    .select(CAMP_COLUMNS.join(","))
    .order("start_date", { ascending: true })
    .order("id", { ascending: true });

  if (error || !Array.isArray(data) || data.some((row) => !isCamp(row))) {
    return { error: "load-failed", camps: [] };
  }

  return { error: null, camps: data.map(pickCamp) };
}

