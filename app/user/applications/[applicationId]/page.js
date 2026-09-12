import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import {
  formatDeadline,
  formatJstDate,
  formatJstDateTime,
  formatMonth,
  formatPeriod,
  formatYen,
  jstToday,
} from "@/app/components/format";
import { statusLabel } from "@/app/components/status-labels";
import { errorMessage } from "@/app/components/messages";
import { getCampApplicationForDetail } from "@/utils/camp-applications/queries";
import { getCommunityApplication } from "@/utils/community-applications/queries";
import { getGroupParticipantApplication } from "@/utils/group-participants/queries";
import { getUserApplicationUsageType } from "@/utils/user-applications/queries";
import { DUE_KINDS, nextAction } from "@/app/user/next-action";
import CampApplicationReview from "./CampApplicationReview";
import CommunityApplicationDetail from "./CommunityApplicationDetail";
import GroupParticipantReview from "./GroupParticipantReview";
import styles from "./page.module.css";

export const metadata = {
  title: "申請詳細｜ひらいずみ志業ポータル",
  description: "申請内容、審査、料金、部屋、滞在の状態を確認します。",
};

function ApplicationNotice({ application }) {
  if (application.status === "revision_requested") {
    return (
      <AlertMessage tone="warning" title="申請内容の修正が必要です">
        <p>{application.decisionReason || "職員からの案内を確認して修正してください。"}</p>
        {application.revisionDueAt && (
          <p>修正期限：{formatDeadline(application.revisionDueAt)}</p>
        )}
      </AlertMessage>
    );
  }
  if (application.status === "rejected") {
    return (
      <AlertMessage tone="error" title="この申請は許可されませんでした">
        <p>{application.decisionReason || "詳細は担当職員へお問い合わせください。"}</p>
      </AlertMessage>
    );
  }
  if (application.status === "approved") {
    return (
      <AlertMessage tone="success" title="利用が許可されました">
        {application.approvalComment && <p>{application.approvalComment}</p>}
      </AlertMessage>
    );
  }
  return null;
}

function ChargeSection({ application }) {
  const charge = application.charge;
  const breakdown = charge?.months ?? application.estimatedCharge.months;
  const total = charge?.total_amount ?? application.estimatedCharge.totalAmount;

  return (
    <section className={styles.panel} aria-labelledby="charge-heading">
      <div className={styles.panelHeading}>
        <h2 id="charge-heading">料金</h2>
        {charge ? (
          <StatusRow>
            <StatusBadge kind="payment" value={charge.payment_status} showKind />
            {charge.is_overdue && <strong className={styles.overdue}>期限超過</strong>}
          </StatusRow>
        ) : (
          <p>提出前のため、現在の内容による見込み額です。</p>
        )}
      </div>
      <div className={styles.amount}>
        <span>{charge ? "合計" : "合計見込み"}</span>
        <strong>{formatYen(total)}</strong>
      </div>
      <dl className={styles.months}>
        {breakdown.map((row) => {
          const month = row.month;
          const usageDays = row.usage_days ?? row.usageDays;
          const dailyRate = row.daily_rate ?? row.dailyRate;
          const amount = row.amount;
          return (
            <div key={month}>
              <dt>{formatMonth(month)}</dt>
              <dd>
                <span>{usageDays}日 × {formatYen(dailyRate)}</span>
                <strong>{formatYen(amount)}</strong>
              </dd>
            </div>
          );
        })}
      </dl>
      {charge?.payment_due_date && (
        <p className={styles.note}>納付期限：{formatJstDate(charge.payment_due_date)}</p>
      )}
      {charge?.paid_at && (
        <p className={styles.note}>納付確認日時：{formatJstDateTime(charge.paid_at)}</p>
      )}
    </section>
  );
}

function StaySection({ application }) {
  const room = application.roomAllocation;
  const stay = application.stay;
  return (
    <section className={styles.panel} aria-labelledby="stay-heading">
      <div className={styles.panelHeading}>
        <h2 id="stay-heading">許可された部屋と滞在</h2>
        {stay && <StatusBadge kind="stay" value={stay.status} showKind />}
      </div>
      {room ? (
        <dl className={styles.facts}>
          <div><dt>部屋</dt><dd>{room.room_name}</dd></div>
          <div><dt>利用人数</dt><dd>{room.people_count}人</dd></div>
          <div><dt>部屋の利用期間</dt><dd>{formatPeriod(room.start_date, room.end_date)}</dd></div>
          {stay?.checked_in_at && <div><dt>入居日時</dt><dd>{formatJstDateTime(stay.checked_in_at)}</dd></div>}
          {stay?.checked_out_at && <div><dt>退去日時</dt><dd>{formatJstDateTime(stay.checked_out_at)}</dd></div>}
        </dl>
      ) : (
        <EmptyState
          title="部屋はまだ決まっていません"
          description="利用が許可され、部屋が決まるとここに表示されます。"
        />
      )}
    </section>
  );
}

export default async function CampApplicationDetailPage({ params }) {
  const { applicationId } = await params;
  const kind = await getUserApplicationUsageType(applicationId, `/user/applications/${applicationId}`);
  if (kind.usageType === "community_group") {
    const result = await getGroupParticipantApplication(applicationId, "detail");
    if (result.error || !result.application) return <PageShell title="団体参加者の申請詳細"><AlertMessage tone="error" title="申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></PageShell>;
    const application = result.application;
    const editable = application.can_edit && ["draft", "revision_requested"].includes(application.status);
    return <PageShell title="団体参加者の申請詳細" description={application.group_name}>
      <StatusRow><StatusBadge kind="application" value={application.status} showKind /><StatusBadge kind="group" value={application.group_status} showKind /></StatusRow>
      {application.status === "revision_requested" && <AlertMessage tone="warning" title="申請内容の修正が必要です"><p>{application.decision_reason || "町からの案内を確認して修正してください。"}</p>{application.active_deadline && <p>再提出の期限：{formatDeadline(application.active_deadline)}</p>}</AlertMessage>}
      {application.status === "rejected" && <AlertMessage tone="error" title="この参加者申請は許可されませんでした"><p>{application.decision_reason || "団体の代表者または町の担当へお問い合わせください。"}</p></AlertMessage>}
      {application.status === "approved" && <AlertMessage tone="success" title="参加者申請が許可されました"><p>団体全体の利用状態は、団体の代表者からの案内もご確認ください。</p></AlertMessage>}
      <AlertMessage tone="info" title="次にすること"><p>{application.status === "draft" ? "本人情報を入力し、確認画面から提出してください。" : application.status === "revision_requested" ? "町からの案内を確認し、期限内に修正して再提出してください。" : ["submitted", "under_review"].includes(application.status) ? "町が内容を確認しています。審査結果をお待ちください。" : "団体と町からの案内をご確認ください。"}</p></AlertMessage>
      <section className={styles.panel} aria-labelledby="group-participant-receipt-heading"><h2 id="group-participant-receipt-heading">受付情報</h2>
        <dl className={styles.facts}>
          <div><dt>受付番号</dt><dd className={styles.reception}>{application.reception_number ?? "未発行"}</dd></div>
          <div><dt>提出日時</dt><dd>{application.last_submitted_at ? formatJstDateTime(application.last_submitted_at) : "未提出"}</dd></div>
          <div><dt>利用期間</dt><dd>{formatPeriod(application.start_date, application.end_date)}</dd></div>
        </dl>
      </section>
      <GroupParticipantReview application={application} />
      <div className={styles.actions}>{editable && <LinkButton href={`/user/applications/${application.id}/edit`} variant="primary" fullWidthOnMobile>申請内容を編集する</LinkButton>}
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></div>
    </PageShell>;
  }
  if (kind.usageType === "community_individual") {
    const result = await getCommunityApplication(applicationId, "detail");
    if (result.error || !result.application) return <PageShell title="地域活動の個人申請詳細"><AlertMessage tone="error" title="申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></PageShell>;
    return <PageShell title="地域活動の個人申請詳細" description="申請内容、審査、料金、部屋、滞在の状態を確認できます。"><CommunityApplicationDetail application={result.application} /></PageShell>;
  }
  const { error, application } = await getCampApplicationForDetail(applicationId);

  if (error || !application) {
    return (
      <PageShell title="キャンプ申請詳細">
        <AlertMessage tone="error" title="申請を開けませんでした">
          <p>{errorMessage(error)}</p>
        </AlertMessage>
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton>
      </PageShell>
    );
  }

  const editable = ["draft", "revision_requested"].includes(application.status);
  const action = nextAction(
    { ...application, revision_due_at: application.revisionDueAt },
    jstToday(),
  );

  return (
    <PageShell title="キャンプ申請詳細" description={application.campName}>
      <StatusRow>
        <StatusBadge kind="application" value={application.status} showKind />
        {application.charge && <StatusBadge kind="payment" value={application.charge.payment_status} showKind />}
        {application.stay && <StatusBadge kind="stay" value={application.stay.status} showKind />}
      </StatusRow>

      <ApplicationNotice application={application} />

      <AlertMessage tone="info" title="次にすること">
        <p>{action.summary}</p>
        {action.due && (
          <p>
            {action.due.label}：
            {action.due.kind === DUE_KINDS.boundary
              ? formatDeadline(action.due.value)
              : formatJstDate(action.due.value)}
          </p>
        )}
      </AlertMessage>

      <section className={styles.panel} aria-labelledby="receipt-heading">
        <h2 id="receipt-heading">受付情報</h2>
        <dl className={styles.facts}>
          <div><dt>受付番号</dt><dd className={styles.reception}>{application.receptionNumber ?? "未発行"}</dd></div>
          <div><dt>提出日時</dt><dd>{application.lastSubmittedAt ? formatJstDateTime(application.lastSubmittedAt) : "未提出"}</dd></div>
          <div><dt>利用期間</dt><dd>{formatPeriod(application.startDate, application.endDate)}</dd></div>
        </dl>
      </section>

      <CampApplicationReview application={application} showEstimatedCharge={false} />
      <ChargeSection application={application} />
      <StaySection application={application} />

      <section className={styles.panel} aria-labelledby="history-heading">
        <h2 id="history-heading">申請状態の履歴</h2>
        {application.history.length > 0 ? (
          <ol className={styles.history}>
            {application.history.map((event, index) => (
              <li key={`${event.occurredAt}-${index}`}>
                <p className={styles.historyStatus}>
                  {event.fromStatus ? `${statusLabel("application", event.fromStatus)} → ` : ""}
                  <strong>{statusLabel("application", event.toStatus)}</strong>
                </p>
                {event.publicReason && <p>{event.publicReason}</p>}
                <time dateTime={event.occurredAt}>{formatJstDateTime(event.occurredAt)}</time>
              </li>
            ))}
          </ol>
        ) : (
          <EmptyState title="申請状態の履歴はまだありません" />
        )}
      </section>

      <div className={styles.actions}>
        {editable && (
          <LinkButton href={`/user/applications/${application.id}/edit`} variant="primary" fullWidthOnMobile>
            申請内容を編集する
          </LinkButton>
        )}
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
