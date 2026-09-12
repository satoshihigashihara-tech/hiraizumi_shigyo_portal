import Link from "next/link";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import { formatDeadline, formatJstDate, formatJstDateTime, formatPeriod, formatYen } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { USAGE_TYPE_LABELS } from "@/app/components/status-labels";
import { getUserApplications } from "@/utils/user-applications/queries";
import styles from "./page.module.css";

export const metadata = {
  title: "申請一覧｜ひらいずみ志業ポータル",
  description: "過去の申請と現在の進行状況を一覧で確認できます。",
};

function usageTypeLabel(value) {
  return value && Object.hasOwn(USAGE_TYPE_LABELS, value) ? USAGE_TYPE_LABELS[value] : "利用区分未設定";
}

function ApplicationListItem({ row }) {
  const resubmitted = row.last_submitted_at && row.last_submitted_at !== row.submitted_at;
  return <li className={styles.card}>
    <h3 className={styles.cardTitle}>{row.camp_name || usageTypeLabel(row.usage_type)}{row.original_application_id && "（継続申請）"}</h3>
    <StatusRow>
      <StatusBadge kind="application" value={row.status} showKind />
      {row.charge && <StatusBadge kind="payment" value={row.charge.payment_status} showKind />}
      {row.stay && <StatusBadge kind="stay" value={row.stay.status} showKind />}
    </StatusRow>
    <dl className={styles.facts}>
      <div className={styles.fact}><dt className={styles.factKey}>利用区分</dt><dd className={styles.factValue}>{usageTypeLabel(row.usage_type)}</dd></div>
      {row.original_application_id && <div className={styles.fact}><dt className={styles.factKey}>申請区分</dt><dd className={styles.factValue}>継続申請（<Link className={styles.inlineLink} href={`/user/applications/${row.original_application_id}`}>元の申請を見る</Link>）</dd></div>}
      <div className={styles.fact}><dt className={styles.factKey}>利用期間</dt><dd className={styles.factValue}>{row.start_date && row.end_date ? formatPeriod(row.start_date, row.end_date) : "未設定"}{row.status === "revision_requested" && "（修正中の候補日程は詳細で確認できます）"}</dd></div>
      <div className={styles.fact}><dt className={styles.factKey}>受付番号</dt><dd className={styles.factValue}>{row.reception_number || "未発行"}</dd></div>
      {row.submitted_at && <div className={styles.fact}><dt className={styles.factKey}>提出日時</dt><dd className={styles.factValue}>{formatJstDateTime(row.submitted_at)}</dd></div>}
      {resubmitted && <div className={styles.fact}><dt className={styles.factKey}>再提出日時</dt><dd className={styles.factValue}>{formatJstDateTime(row.last_submitted_at)}</dd></div>}
      {row.revision_due_at && <div className={styles.fact}><dt className={styles.factKey}>再提出の期限</dt><dd className={styles.factValue}>{formatDeadline(row.revision_due_at)}</dd></div>}
      {row.charge && <><div className={styles.fact}><dt className={styles.factKey}>料金</dt><dd className={styles.factValue}>{formatYen(row.charge.total_amount)}</dd></div>
        <div className={styles.fact}><dt className={styles.factKey}>納付期限</dt><dd className={styles.factValue}>{row.charge.payment_due_date ? formatJstDate(row.charge.payment_due_date) : "未設定"}{row.charge.is_overdue && "（期限超過）"}</dd></div></>}
      {row.room && <div className={styles.fact}><dt className={styles.factKey}>部屋</dt><dd className={styles.factValue}>{row.room.name}</dd></div>}
      <div className={styles.fact}><dt className={styles.factKey}>最終更新</dt><dd className={styles.factValue}>{formatJstDateTime(row.updated_at)}</dd></div>
    </dl>
    {row.decision_reason && <p className={styles.reason}><span className={styles.reasonKey}>町からの連絡：</span>{row.decision_reason}</p>}
    <div className={styles.cardLink}>{row.detail_path ? <LinkButton href={row.detail_path} fullWidthOnMobile>申請の詳細を見る</LinkButton>
      : <p className={styles.note}>この利用区分の詳細画面は準備中です。</p>}</div>
  </li>;
}

export default async function UserApplicationsPage() {
  const result = await getUserApplications();
  return <PageShell title="申請一覧" description="提出した申請と、提出前の下書きを表示します。">
    <div className={styles.actions}><LinkButton href="/user/applications/new" variant="primary" fullWidthOnMobile>新しく申請する</LinkButton><LinkButton href="/user" fullWidthOnMobile>利用者ホームへ戻る</LinkButton></div>
    {result.error ? <AlertMessage tone="error" title="申請を読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
      : result.applications.length === 0 ? <EmptyState title="申請はまだありません" description="新しく申請すると、提出前の下書きもこの画面に表示されます。" />
        : <section className={styles.section} aria-labelledby="applications-heading"><h2 className={styles.sectionTitle} id="applications-heading">申請の一覧</h2>
          <p className={styles.note}>{result.applications.length}件の申請があります。新しく登録したものから表示しています。</p>
          <ul className={styles.cardList} role="list">{result.applications.map((row) => <ApplicationListItem key={row.id} row={row} />)}</ul>
        </section>}
  </PageShell>;
}
