import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import { formatDeadline, formatJstDate, formatJstDateTime, formatPeriod, formatYen } from "@/app/components/format";
import { statusLabel } from "@/app/components/status-labels";
import CommunityApplicationReview from "./CommunityApplicationReview";
import styles from "./page.module.css";

function Notice({ application }) {
  if (application.status === "revision_requested") return <AlertMessage tone="warning" title="申請内容の修正が必要です"><p>{application.decision_reason || "町からの案内を確認して修正してください。"}</p>{application.revision_due_at && <p>修正期限：{formatDeadline(application.revision_due_at)}</p>}</AlertMessage>;
  if (application.status === "rejected") return <AlertMessage tone="error" title="この申請は許可されませんでした"><p>{application.decision_reason || "詳細は町の担当へお問い合わせください。"}</p></AlertMessage>;
  if (application.status === "approved") return <AlertMessage tone="success" title="利用が許可されました">{application.approval_comment && <p>{application.approval_comment}</p>}</AlertMessage>;
  return null;
}

function nextStep(status) {
  if (status === "draft") return "申請内容を入力し、確認画面から提出してください。";
  if (status === "revision_requested") return "町からの案内を確認し、期限内に内容を修正して再提出してください。";
  if (["submitted", "under_review"].includes(status)) return "職員が内容を確認しています。審査結果をお待ちください。";
  if (status === "approved") return "納付状態と利用する部屋を確認してください。";
  if (status === "cancellation_requested") return "キャンセルの確認結果をお待ちください。";
  return "この申請に関する案内をご確認ください。";
}

export default function CommunityApplicationDetail({ application, cancellation, extension }) {
  const periodStart = application.reserved_start_date ?? application.fields.start_date;
  const periodEnd = application.reserved_end_date ?? application.fields.end_date;
  const room = application.room_allocation?.is_current ? application.room_allocation : null;
  const editable = application.can_edit && ["draft", "revision_requested"].includes(application.status);
  return <>
    <StatusRow><StatusBadge kind="application" value={application.status} showKind />
      {application.charge && <StatusBadge kind="payment" value={application.charge.payment_status} showKind />}
      {application.stay && <StatusBadge kind="stay" value={application.stay.status} showKind />}</StatusRow>
    <Notice application={application} />
    <AlertMessage tone="info" title="次にすること"><p>{nextStep(application.status)}</p></AlertMessage>

    <section className={styles.panel} aria-labelledby="community-receipt-heading"><h2 id="community-receipt-heading">受付情報</h2>
      <dl className={styles.facts}>
        <div><dt>受付番号</dt><dd className={styles.reception}>{application.reception_number ?? "未発行"}</dd></div>
        <div><dt>提出日時</dt><dd>{application.last_submitted_at ? formatJstDateTime(application.last_submitted_at) : "未提出"}</dd></div>
        <div><dt>利用期間</dt><dd>{periodStart && periodEnd ? formatPeriod(periodStart, periodEnd) : "未設定"}</dd></div>
      </dl>
    </section>

    <CommunityApplicationReview application={application} showEstimatedCharge={false} />

    <section className={styles.panel} aria-labelledby="community-charge-detail-heading"><div className={styles.panelHeading}><h2 id="community-charge-detail-heading">料金</h2>
      {application.charge ? <StatusBadge kind="payment" value={application.charge.payment_status} showKind /> : <p>提出前のため、現在の内容による見込み額です。</p>}</div>
      <div className={styles.amount}><span>{application.charge ? "合計" : "合計見込み"}</span><strong>{formatYen(application.charge?.total_amount ?? application.estimated_months.reduce((sum, row) => sum + row.amount, 0))}</strong></div>
      {application.charge?.payment_due_date && <p className={styles.note}>納付期限：{formatJstDate(application.charge.payment_due_date)}{application.charge.is_overdue && "（期限超過）"}</p>}
    </section>

    <section className={styles.panel} aria-labelledby="community-room-heading"><div className={styles.panelHeading}><h2 id="community-room-heading">許可された部屋と滞在</h2>{application.stay && <StatusBadge kind="stay" value={application.stay.status} showKind />}</div>
      {room ? <dl className={styles.facts}><div><dt>部屋</dt><dd>{room.room_name}</dd></div><div><dt>利用期間</dt><dd>{formatPeriod(room.start_date, room.end_date)}</dd></div>
        {application.stay?.checked_in_at && <div><dt>入居日時</dt><dd>{formatJstDateTime(application.stay.checked_in_at)}</dd></div>}
        {application.stay?.checked_out_at && <div><dt>退去日時</dt><dd>{formatJstDateTime(application.stay.checked_out_at)}</dd></div>}</dl>
        : <EmptyState title="部屋はまだ決まっていません" description="利用が許可され、部屋が決まるとここに表示されます。" />}
    </section>

    <section className={styles.panel} aria-labelledby="community-history-heading"><h2 id="community-history-heading">申請状態の履歴</h2>
      {application.events.length ? <ol className={styles.history}>{application.events.map((event, index) => <li key={`${event.occurred_at}-${index}`}>
        <p className={styles.historyStatus}>{event.from_status ? `${statusLabel("application", event.from_status)} → ` : ""}<strong>{statusLabel("application", event.to_status)}</strong></p>
        {event.public_reason && <p>{event.public_reason}</p>}<time dateTime={event.occurred_at}>{formatJstDateTime(event.occurred_at)}</time>
      </li>)}</ol> : <EmptyState title="申請状態の履歴はまだありません" />}
    </section>

    <div className={styles.actions}>{editable && <LinkButton href={`/user/applications/${application.id}/edit`} variant="primary" fullWidthOnMobile>申請内容を編集する</LinkButton>}
      {cancellation?.can_request && <LinkButton href={`/user/applications/${application.id}/cancel`} variant="danger" fullWidthOnMobile>取消を申請する</LinkButton>}
      {extension?.can_extend && <LinkButton href={`/user/applications/${application.id}/extension`} fullWidthOnMobile>継続申請を開始する</LinkButton>}
      {extension?.existing_extension_id && <LinkButton href={`/user/applications/${extension.existing_extension_id}`} fullWidthOnMobile>作成済みの継続申請を見る</LinkButton>}
      <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></div>
  </>;
}
