/*
 * 日本時間・金額の整形関数。
 *
 * すべて Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo" }) を使い、
 * 実行環境のタイムゾーンに依存させない。サーバー（UTC想定）とブラウザで
 * 結果が変わると、ハイドレーション不一致と表示ずれの両方が起きるため。
 *
 * docs/requirements.md 6.2：画面では「2026年9月8日 23:59」のように表示する。
 * docs/database.md 8章：期限はDBに翌日00:00の排他的境界を保存し、
 *                      表示は1分引いた時刻を用いる。
 *
 * 依存なしの純粋モジュール。
 */

const TIME_ZONE = "Asia/Tokyo";
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

const dateFormatter = new Intl.DateTimeFormat("ja-JP", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "long",
  day: "numeric",
});

const dateTimeFormatter = new Intl.DateTimeFormat("ja-JP", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "long",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

const monthFormatter = new Intl.DateTimeFormat("ja-JP", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "long",
});

const yenFormatter = new Intl.NumberFormat("ja-JP");

/**
 * 文字列を Date へ変換する。不正値は null。
 * "YYYY-MM-DD" は JavaScript ではUTCの0時として解釈され、日本時間で表示すると
 * 9時間ずれて同じ日になる（日付だけなら問題ないが境界が分かりにくい）ため、
 * 明示的に日本時間の正午へ寄せて日付がずれないようにする。
 */
function toDate(value) {
  if (typeof value !== "string" || value === "") return null;
  const source = DATE_ONLY.test(value) ? `${value}T12:00:00+09:00` : value;
  const parsed = new Date(source);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/**
 * 日付を「2026年9月10日」の形式で返す。
 *
 * @param {string|null|undefined} value "YYYY-MM-DD" またはタイムスタンプ文字列
 * @returns {string} 整形結果。不正値は空文字
 */
export function formatJstDate(value) {
  const date = toDate(value);
  return date ? dateFormatter.format(date) : "";
}

/**
 * 日時を「2026年9月8日 23:59」の形式で返す（docs/requirements.md 6.2）。
 *
 * "YYYY-MM-DD"（fields.start_date など、時刻を持たない値）を渡された場合は
 * 時刻を出さず formatJstDate に委譲する。toDate が日本時間の正午へ寄せる都合で
 * そのまま整形すると「2026年10月11日 12:00」という、データに存在しない時刻を
 * 画面へ出してしまい、渡し間違いに気づけなくなるため。
 * 空文字ではなく日付を返すのは、日付そのものは正しい情報で、
 * 消すと利用者から必要な情報が見えなくなるから。
 *
 * @param {string|null|undefined} value タイムスタンプ文字列
 * @returns {string} 整形結果。不正値は空文字
 */
export function formatJstDateTime(value) {
  if (typeof value === "string" && DATE_ONLY.test(value)) {
    return formatJstDate(value);
  }
  const date = toDate(value);
  return date ? dateTimeFormatter.format(date) : "";
}

/**
 * 期限を表示用に整形する。
 * DBの保存値は「その分の次の分の00秒」という排他的境界のため、1分引いて表示する
 * （docs/database.md 8章・docs/routes.md 9.4）。
 * 例：2026-10-01T00:00+09:00 → 「2026年9月30日 23:59」
 *
 * @param {string|null|undefined} value DBに保存された排他的境界のタイムスタンプ
 * @returns {string} 整形結果。不正値は空文字
 */
export function formatDeadline(value) {
  const date = toDate(value);
  if (!date) return "";
  return dateTimeFormatter.format(new Date(date.getTime() - 60_000));
}

/**
 * 利用期間を「2026年9月10日 〜 2026年9月12日」の形式で返す。
 * 片方でも欠けていれば「未定」（下書きは日程未設定があり得るため）。
 *
 * @param {string|null|undefined} startDate "YYYY-MM-DD"
 * @param {string|null|undefined} endDate "YYYY-MM-DD"
 * @returns {string}
 */
export function formatPeriod(startDate, endDate) {
  const start = formatJstDate(startDate);
  const end = formatJstDate(endDate);
  if (!start || !end) return "未定";
  return `${start} 〜 ${end}`;
}

/**
 * 金額を「9,600円」の形式で返す。
 *
 * @param {number|null|undefined} amount 整数の金額
 * @returns {string} 整形結果。整数以外は空文字
 */
export function formatYen(amount) {
  if (!Number.isInteger(amount)) return "";
  return `${yenFormatter.format(amount)}円`;
}

/**
 * 料金内訳の月を「2026年8月」の形式で返す（charge_months.month は各月1日）。
 *
 * @param {string|null|undefined} value "YYYY-MM-DD" またはタイムスタンプ文字列
 * @returns {string} 整形結果。不正値は空文字
 */
export function formatMonth(value) {
  const date = toDate(value);
  return date ? monthFormatter.format(date) : "";
}

/**
 * "YYYY-MM-DD" を、実在する日付のときだけUTCの時刻値へ変換する。
 *
 * Date.UTC は範囲外の値を繰り上げる（2月31日→3月3日、13月→翌年1月）ため、
 * 形式が合っているだけの "2026-02-31" をそのまま通すと日数が黙って計算できてしまう。
 * 作った Date から年月日を取り出して入力と一致するか確かめれば、繰り上がりを検出できる。
 * 2桁年がDate.UTCで1900年代へ写される件（"0026" → 1926年）も同じ確認で弾ける。
 *
 * @param {string} value DATE_ONLY を満たす文字列
 * @returns {number|null} UTCのミリ秒。実在しない日付なら null
 */
function utcDayTime(value) {
  const [year, month, day] = value.split("-").map(Number);
  const time = Date.UTC(year, month - 1, day);
  const date = new Date(time);
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    return null;
  }
  return time;
}

/**
 * 利用日数（両端を含む）を返す。表示補助のみで、料金の確定はサーバー側が行う
 * （docs/requirements.md 16.1：開始日と終了日の両方を使用日数へ含める）。
 *
 * @param {string|null|undefined} startDate "YYYY-MM-DD"
 * @param {string|null|undefined} endDate "YYYY-MM-DD"
 * @returns {number|null} 日数。実在しない日付・開始日が終了日より後なら null
 */
export function countStayDays(startDate, endDate) {
  if (!DATE_ONLY.test(startDate ?? "") || !DATE_ONLY.test(endDate ?? "")) {
    return null;
  }
  const start = utcDayTime(startDate);
  const end = utcDayTime(endDate);
  if (start === null || end === null || end < start) return null;
  return Math.round((end - start) / 86_400_000) + 1;
}

/**
 * 日本時間の「今日」を "YYYY-MM-DD" で返す。
 * 納付の期限超過判定（status-labels.js の isPaymentOverdue）に渡す。
 *
 * 実行するたびに結果が変わるため、Server Componentで1度だけ求めて
 * propsで配り、Client Component側で呼ばない（ハイドレーション不一致の防止）。
 *
 * @param {Date} [now] 判定の基準時刻。省略時は現在時刻
 * @returns {string} "YYYY-MM-DD"
 */
export function jstToday(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
  return parts;
}
