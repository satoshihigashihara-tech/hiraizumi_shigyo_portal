import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getPublicCalendar } from "@/utils/calendar/queries";
import {
  calendarMonthLabel,
  currentJstMonth,
  firstWeekday,
  normalizeCalendarMonth,
  shiftCalendarMonth,
} from "@/utils/calendar/month";
import styles from "./page.module.css";

const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];
const AVAILABILITY = {
  available: { label: "申請可能", className: "available" },
  unavailable: { label: "利用不可", className: "unavailable" },
  not_yet_open: { label: "受付開始前", className: "notYetOpen" },
};

export const metadata = {
  title: "利用状況カレンダー｜ひらいずみ志業ポータル",
  description: "平泉町志業シェアハウスの利用可否を月ごとに確認できます。",
};

export default async function PublicCalendarPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const currentMonth = currentJstMonth();
  const month = normalizeCalendarMonth(query.month, currentMonth);
  const result = await getPublicCalendar(month);
  const offset = firstWeekday(month);

  return (
    <PageShell title="利用状況カレンダー" description="日付ごとの申請受付状況を確認できます。表示内容は最新の状況と異なる場合があります。">
      <nav className={styles.monthNavigation} aria-label="表示する月">
        <LinkButton href={`/calendar?month=${shiftCalendarMonth(month, -1)}`}>前の月</LinkButton>
        {month !== currentMonth && <LinkButton href={`/calendar?month=${currentMonth}`}>今月</LinkButton>}
        <LinkButton href={`/calendar?month=${shiftCalendarMonth(month, 1)}`}>次の月</LinkButton>
      </nav>

      <section className={styles.calendarSection} aria-labelledby="calendar-month">
        <h2 className={styles.monthTitle} id="calendar-month">{calendarMonthLabel(month)}</h2>
        <ul className={styles.legend} aria-label="利用可否の説明">
          {Object.entries(AVAILABILITY).map(([value, item]) => (
            <li className={`${styles.legendItem} ${styles[item.className]}`} key={value}>{item.label}</li>
          ))}
        </ul>

        {result.error ? (
          <AlertMessage tone="error" title="カレンダーを読み込めませんでした">
            <p>{errorMessage(result.error)}</p>
          </AlertMessage>
        ) : (
          <>
            <div className={styles.calendarHeader} aria-hidden="true">
              {WEEKDAYS.map((weekday) => (
                <div className={styles.weekday} key={weekday}>{weekday}</div>
              ))}
            </div>
            <ol className={styles.calendarDays} aria-label={`${calendarMonthLabel(month)}の日別利用状況`}>
              {result.days.map((day) => {
                const availability = AVAILABILITY[day.availability];
                return (
                  <li
                    className={`${styles.day} ${styles[availability.className]}`}
                    key={day.date}
                    style={day === result.days[0] ? { gridColumnStart: offset + 1 } : undefined}
                  >
                    <time className={styles.dayNumber} dateTime={day.date}>{Number(day.date.slice(-2))}</time>
                    <span className={styles.dayStatus}>{availability.label}</span>
                  </li>
                );
              })}
            </ol>
          </>
        )}
      </section>

      <p className={styles.note}>「申請可能」の日でも、申請の提出時に定員やほかの日程との重複を再確認します。申請した時点では利用は確定しません。</p>
      <div className={styles.actions}>
        <LinkButton href="/" fullWidthOnMobile>トップへ戻る</LinkButton>
        <LinkButton href="/login?returnTo=%2Fuser%2Fapplications%2Fnew" variant="primary" fullWidthOnMobile>ログインして申請へ進む</LinkButton>
      </div>
    </PageShell>
  );
}
