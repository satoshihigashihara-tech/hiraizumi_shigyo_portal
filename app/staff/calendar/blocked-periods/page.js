import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getStaffBlockedPeriods } from "@/utils/calendar/queries";
import { calendarMonthLabel, currentJstMonth, normalizeCalendarMonth, shiftCalendarMonth } from "@/utils/calendar/month";
import styles from "../calendar.module.css";

export const metadata = { title: "利用停止期間｜ひらいずみ志業ポータル" };

export default async function StaffBlockedPeriodsPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const month = normalizeCalendarMonth(query.month, currentJstMonth());
  const result = await getStaffBlockedPeriods(month);
  const updated = Array.isArray(query.updated) ? query.updated[0] : query.updated;
  return (
    <PageShell title="利用停止期間" description="清掃、修繕、町行事など、申請を受け付けない期間を管理します。内部理由は一般利用者へ表示しません。">
      <div className={styles.actions}>
        <LinkButton href="/staff/calendar/blocked-periods/new" variant="primary" fullWidthOnMobile>新しい利用停止期間を作る</LinkButton>
        <LinkButton href={`/staff/calendar?month=${month}`} fullWidthOnMobile>職員カレンダーへ戻る</LinkButton>
      </div>
      {updated === "saved" && <AlertMessage tone="success" title="利用停止期間を保存しました" />}
      {updated === "deleted" && <AlertMessage tone="success" title="利用停止期間を削除しました" />}
      <nav className={styles.monthNavigation} aria-label="一覧の月">
        <LinkButton href={`/staff/calendar/blocked-periods?month=${shiftCalendarMonth(month, -1)}`}>前の月</LinkButton>
        <strong>{calendarMonthLabel(month)}</strong>
        <LinkButton href={`/staff/calendar/blocked-periods?month=${shiftCalendarMonth(month, 1)}`}>次の月</LinkButton>
      </nav>
      {result.error ? <AlertMessage tone="error" title="利用停止期間を読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
        : result.periods.length === 0 ? <EmptyState title="この月の利用停止期間はありません" description="必要な場合は、新しい利用停止期間を作成してください。" />
          : <section aria-labelledby="blocked-period-list-heading"><h2 className={styles.sectionTitle} id="blocked-period-list-heading">登録済みの利用停止期間</h2>
            <ul className={styles.entryList}>{result.periods.map((period) => <li className={styles.entryCard} key={period.entry_id}>
              <h3>{formatPeriod(period.start_date, period.end_date)}</h3>
              <dl className={styles.facts}><div><dt>内部理由</dt><dd>{period.internal_reason || "理由未設定"}</dd></div></dl>
              <LinkButton href={`/staff/calendar/blocked-periods/${period.entry_id}/edit`} fullWidthOnMobile>編集・削除する</LinkButton>
            </li>)}</ul></section>}
    </PageShell>
  );
}
