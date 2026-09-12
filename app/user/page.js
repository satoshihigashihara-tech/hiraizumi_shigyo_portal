import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import { formatDeadline, formatJstDate, formatPeriod, jstToday } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { USAGE_TYPE_LABELS } from "@/app/components/status-labels";
import { getUserHomeApplications } from "@/utils/user-applications/queries";
import { DUE_KINDS, needsUserAction, nextAction } from "./next-action";
import styles from "./page.module.css";
import { modeFromSearchParams } from "@/utils/navigation/mode";

export const metadata = {
  title: "利用者ホーム｜ひらいずみ志業ポータル",
  description: "自分の申請の状態と、次に必要な操作を確認できます。",
};

function usageTypeLabel(value) {
  return value && Object.hasOwn(USAGE_TYPE_LABELS, value)
    ? USAGE_TYPE_LABELS[value]
    : "利用区分未設定";
}

function applicationTitle(application) {
  return application.camp_name || usageTypeLabel(application.usage_type);
}

function formatDue(due) {
  if (!due) return "";
  return due.kind === DUE_KINDS.boundary
    ? formatDeadline(due.value)
    : formatJstDate(due.value);
}

function ActionLink({ action }) {
  return action.href ? (
    <LinkButton href={action.href} fullWidthOnMobile>
      {action.linkLabel}
    </LinkButton>
  ) : (
    <p className={styles.note}>この利用区分の詳細画面は準備中です。</p>
  );
}

function ApplicationCard({ application, today }) {
  const action = nextAction(application, today);
  const dueText =
    action.due?.value === application.charge?.payment_due_date
      ? ""
      : formatDue(action.due);

  return (
    <li className={styles.card}>
      <h3 className={styles.cardTitle}>{applicationTitle(application)}</h3>
      <StatusRow>
        <StatusBadge kind="application" value={application.status} showKind />
        {application.charge && (
          <StatusBadge kind="payment" value={application.charge.payment_status} showKind />
        )}
        {application.stay && (
          <StatusBadge kind="stay" value={application.stay.status} showKind />
        )}
      </StatusRow>

      <dl className={styles.facts}>
        <div className={styles.fact}>
          <dt className={styles.factKey}>利用区分</dt>
          <dd className={styles.factValue}>{usageTypeLabel(application.usage_type)}</dd>
        </div>
        <div className={styles.fact}>
          <dt className={styles.factKey}>利用期間</dt>
          <dd className={styles.factValue}>
            {application.start_date && application.end_date
              ? formatPeriod(application.start_date, application.end_date)
              : "未設定"}
          </dd>
        </div>
        {application.charge?.payment_due_date && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>納付の期限</dt>
            <dd className={styles.factValue}>
              {formatJstDate(application.charge.payment_due_date)}
              {application.charge.is_overdue && "（期限を過ぎています）"}
            </dd>
          </div>
        )}
        <div className={styles.fact}>
          <dt className={styles.factKey}>受付番号</dt>
          <dd className={styles.factValue}>{application.reception_number || "未発行"}</dd>
        </div>
      </dl>

      <div className={styles.action}>
        <p className={styles.actionSummary}>{action.summary}</p>
        {dueText && (
          <p className={styles.actionDue}>
            {action.due.label}：{dueText}
            {action.overdue && "（期限を過ぎています）"}
          </p>
        )}
        {application.decision_reason && (
          <p className={styles.reason}>
            <span className={styles.reasonKey}>町からの連絡：</span>
            {application.decision_reason}
          </p>
        )}
        <div className={styles.cardLink}>
          <ActionLink action={action} />
        </div>
      </div>
    </li>
  );
}

export default async function UserHomePage({ searchParams }) {
  const mode = modeFromSearchParams((await searchParams) ?? {});
  const result = await getUserHomeApplications(mode);
  const today = jstToday();
  const actionNeeded = result.applications.filter((application) =>
    needsUserAction(application, today),
  );

  return (
    <PageShell audienceMode={mode} title="利用者ホーム" description="申請の状態と、次に必要な操作を確認できます。">
      {result.error ? (
        <AlertMessage tone="error" title="申請を読み込めませんでした">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
      ) : result.applications.length === 0 ? (
        <EmptyState
          title="申請はまだありません"
          description="新しく申請すると、提出前の下書きもこの画面に表示されます。"
          action={
            <LinkButton href="/user/applications/new" variant="primary" fullWidthOnMobile>
              新しく申請する
            </LinkButton>
          }
        />
      ) : (
        <>
          <section className={styles.section} aria-labelledby="next-action-heading">
            <h2 className={styles.sectionTitle} id="next-action-heading">次に必要な操作</h2>
            {actionNeeded.length === 0 ? (
              <p className={styles.note}>いま操作が必要な申請はありません。町からの連絡をお待ちください。</p>
            ) : (
              <ul className={styles.actionList} role="list">
                {actionNeeded.map((application) => {
                  const action = nextAction(application, today);
                  const dueText = formatDue(action.due);
                  return (
                    <li className={styles.actionItem} key={application.id}>
                      <p className={styles.actionItemTitle}>{applicationTitle(application)}</p>
                      <p>{action.summary}</p>
                      {dueText && (
                        <p className={styles.actionDue}>
                          {action.due.label}：{dueText}
                          {action.overdue && "（期限を過ぎています）"}
                        </p>
                      )}
                      <ActionLink action={action} />
                    </li>
                  );
                })}
              </ul>
            )}
          </section>

          <section className={styles.section} aria-labelledby="applications-heading">
            <h2 className={styles.sectionTitle} id="applications-heading">申請の状況</h2>
            <ul className={styles.cardList} role="list">
              {result.applications.slice(0, 3).map((application) => (
                <ApplicationCard application={application} key={application.id} today={today} />
              ))}
            </ul>
            <div className={styles.sectionLink}>
              <LinkButton href="/user/applications" fullWidthOnMobile>申請の一覧を見る</LinkButton>
            </div>
          </section>
        </>
      )}

      <section className={styles.section} aria-labelledby="links-heading">
        <h2 className={styles.sectionTitle} id="links-heading">その他の操作</h2>
        <div className={styles.links}>
          <LinkButton href="/user/applications/new" variant="primary" fullWidthOnMobile>新しく申請する</LinkButton>
          <LinkButton href="/user/applications" fullWidthOnMobile>申請の一覧</LinkButton>
          <LinkButton href="/user/profile" fullWidthOnMobile>プロフィールの確認・変更</LinkButton>
        </div>
      </section>

      <section className={styles.section} aria-labelledby="groups-heading">
        <h2 className={styles.sectionTitle} id="groups-heading">団体での申請</h2>
        <p className={styles.note}>代表者として団体申請を作成し、現在の状態を確認できます。</p>
        <div className={styles.sectionLink}>
          <LinkButton href="/user/groups" fullWidthOnMobile>団体申請の一覧を見る</LinkButton>
        </div>
      </section>
    </PageShell>
  );
}
