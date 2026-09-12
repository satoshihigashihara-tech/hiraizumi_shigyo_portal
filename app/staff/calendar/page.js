import Link from "next/link";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatJstDate, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getStaffCalendar, getStaffCalendarDay } from "@/utils/calendar/queries";
import { isDate } from "@/utils/calendar/validation";
import {
  calendarMonthLabel,
  currentJstMonth,
  firstWeekday,
  normalizeCalendarMonth,
  shiftCalendarMonth,
} from "@/utils/calendar/month";
import styles from "./calendar.module.css";

const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];
const TYPE_LABELS = {
  camp: "キャンプ期間",
  blocked: "利用停止",
  individual: "地域活動・個人",
  application: "個別申請",
  group: "地域活動・団体",
};

export const metadata = { title: "職員カレンダー｜ひらいずみ志業ポータル" };

function daysInMonth(month) {
  const [year, monthNumber] = month.split("-").map(Number);
  return new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
}

function detailPath(entry) {
  if (entry.entry_type === "camp") return `/staff/camps/${entry.entry_id}`;
  if (entry.entry_type === "blocked") return `/staff/calendar/blocked-periods/${entry.entry_id}/edit`;
  if (entry.entry_type === "group") return `/staff/community/groups/${entry.entry_id}`;
  if (["individual", "application"].includes(entry.entry_type)) {
    return entry.camp_id
      ? `/staff/camps/${entry.camp_id}/applications/${entry.entry_id}`
      : `/staff/community/applications/${entry.entry_id}`;
  }
  return null;
}

function includesDate(entry, date) {
  return entry.start_date <= date && entry.end_date >= date;
}

export default async function StaffCalendarPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const currentMonth = currentJstMonth();
  const month = normalizeCalendarMonth(query.month, currentMonth);
  const dateValue = Array.isArray(query.date) ? query.date[0] : query.date;
  const selectedDate = isDate(dateValue) && dateValue.startsWith(`${month}-`) ? dateValue : null;
  const monthResult = await getStaffCalendar(month);
  const dayResult = selectedDate ? await getStaffCalendarDay(selectedDate) : null;
  const dates = Array.from({ length: daysInMonth(month) }, (_, index) => `${month}-${String(index + 1).padStart(2, "0")}`);

  return (
    <PageShell title="職員カレンダー" description="予約の内訳と利用停止期間を確認します。閲覧だけでは状態を変更しません。">
      <div className={styles.actions}>
        <LinkButton href="/staff/calendar/blocked-periods" variant="primary" fullWidthOnMobile>利用停止期間を管理する</LinkButton>
        <LinkButton href="/staff" fullWidthOnMobile>職員ホームへ戻る</LinkButton>
      </div>
      <nav className={styles.monthNavigation} aria-label="表示する月">
        <LinkButton href={`/staff/calendar?month=${shiftCalendarMonth(month, -1)}`}>前の月</LinkButton>
        {month !== currentMonth && <LinkButton href={`/staff/calendar?month=${currentMonth}`}>今月</LinkButton>}
        <LinkButton href={`/staff/calendar?month=${shiftCalendarMonth(month, 1)}`}>次の月</LinkButton>
      </nav>
      <section className={styles.calendarSection} aria-labelledby="staff-calendar-month">
        <h2 className={styles.monthTitle} id="staff-calendar-month">{calendarMonthLabel(month)}</h2>
        <ul className={styles.legend} aria-label="予定の種類">
          {Object.entries(TYPE_LABELS).filter(([type]) => type !== "application").map(([type, label]) => (
            <li className={`${styles.legendItem} ${styles[type]}`} key={type}>{label}</li>
          ))}
        </ul>
        {monthResult.error ? (
          <AlertMessage tone="error" title="職員カレンダーを読み込めませんでした"><p>{errorMessage(monthResult.error)}</p></AlertMessage>
        ) : (
          <>
            <div className={styles.calendarHeader} aria-hidden="true">
              {WEEKDAYS.map((weekday) => <div className={styles.weekday} key={weekday}>{weekday}</div>)}
            </div>
            <ol className={styles.calendarDays} aria-label={`${calendarMonthLabel(month)}の業務予定`}>
              {dates.map((date, index) => {
                const entries = monthResult.entries.filter((entry) => includesDate(entry, date));
                const counts = entries.reduce((values, entry) => ({ ...values, [entry.entry_type]: (values[entry.entry_type] ?? 0) + 1 }), {});
                return (
                  <li className={`${styles.day} ${selectedDate === date ? styles.selectedDay : ""}`} key={date} style={index === 0 ? { gridColumnStart: firstWeekday(month) + 1 } : undefined}>
                    <Link className={styles.dayLink} href={`/staff/calendar?month=${month}&date=${date}`} aria-current={selectedDate === date ? "date" : undefined}>
                      <time className={styles.dayNumber} dateTime={date}>{index + 1}</time>
                      <span className={styles.daySummary}>{entries.length === 0 ? "予定なし" : `${entries.length}件`}</span>
                      <span className={styles.dayKinds} aria-hidden="true">
                        {Object.entries(counts).map(([type, count]) => <span className={styles[type] ?? styles.other} key={type}>{TYPE_LABELS[type] ?? "予定"} {count}</span>)}
                      </span>
                    </Link>
                  </li>
                );
              })}
            </ol>
          </>
        )}
      </section>
      <section className={styles.dayDetails} aria-labelledby="selected-day-heading">
        <h2 id="selected-day-heading">{selectedDate ? `${formatJstDate(selectedDate)}の内訳` : "日別の内訳"}</h2>
        {!selectedDate ? <EmptyState title="日付を選択してください" description="カレンダーの日付を選ぶと、職員だけが確認できる内訳を表示します。" />
          : dayResult?.error ? <AlertMessage tone="error" title="日別の内訳を読み込めませんでした"><p>{errorMessage(dayResult.error)}</p></AlertMessage>
            : dayResult.entries.length === 0 ? <EmptyState title="この日の予定はありません" description="登録済みのキャンプ、申請、団体、利用停止はありません。" />
              : <ul className={styles.entryList}>{dayResult.entries.map((entry) => {
                const path = detailPath(entry);
                return <li className={styles.entryCard} key={`${entry.entry_type}-${entry.entry_id}`}>
                  <div className={styles.entryHeader}><div><p className={styles.entryType}>{TYPE_LABELS[entry.entry_type] ?? "予定"}</p><h3>{entry.display_name || "名称未設定"}</h3></div>
                    {entry.status && ["application", "group"].includes(entry.entry_type) && <StatusBadge kind={entry.entry_type === "group" ? "group" : "application"} value={entry.status} />}</div>
                  <dl className={styles.facts}>
                    <div><dt>利用期間</dt><dd>{formatPeriod(entry.start_date, entry.end_date)}</dd></div>
                    <div><dt>人数</dt><dd>{Number(entry.people_count) || 0}人</dd></div>
                    {entry.reception_number && <div><dt>受付番号</dt><dd>{entry.reception_number}</dd></div>}
                    {entry.internal_reason && <div><dt>内部理由</dt><dd>{entry.internal_reason}</dd></div>}
                  </dl>
                  {path && <LinkButton href={path} fullWidthOnMobile>詳細を確認する</LinkButton>}
                </li>;
              })}</ul>}
      </section>
    </PageShell>
  );
}
