import { notFound, redirect } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import {
  formatDeadline,
  formatJstDate,
  formatJstDateTime,
  formatPeriod,
  formatYen,
} from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { statusLabel, USAGE_PLACE_LABELS } from "@/app/components/status-labels";
import { createGuardianConsentDownloadUrl } from "@/app/actions/guardian-consent";
import { getStaffCommunityApplicationDetail } from "@/utils/application-operations/queries";
import {
  NoteForm,
  PaymentForm,
  StayOperationForm,
  AccountDisableForm,
} from "@/app/staff/camps/[campId]/applications/[applicationId]/OperationForms";
import { ReviewOperations } from "./ReviewForms";
import styles from "./page.module.css";

export const metadata = {
  title: "地域活動の個人申請審査｜ひらいずみ志業ポータル",
};

const UPDATED_MESSAGES = {
  under_review: "審査を開始しました。",
  revision_requested: "修正を依頼しました。",
  rejected: "申請を不許可にしました。",
  approved: "申請を許可しました。",
  "room-assigned": "部屋割りを保存しました。",
  "payment-updated": "納付情報を保存しました。",
  "checked-in": "入居を記録しました。",
  "checked-out": "退去を記録しました。",
  "note-saved": "職員メモを保存しました。",
  cancelled: "キャンセルを確定しました。",
  "account-disabled": "利用者のアカウントを停止しました。",
};

function Fact({ label, children }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{children || "未設定"}</dd>
    </div>
  );
}

export default async function StaffCommunityApplicationPage({ params, searchParams }) {
  const [{ applicationId }, query] = await Promise.all([params, searchParams]);
  const result = await getStaffCommunityApplicationDetail(applicationId);
  if (result.redirectPath) redirect(result.redirectPath);
  if (result.error === "not-found") notFound();
  if (result.error || !result.application) {
    return (
      <PageShell title="地域活動の個人申請審査">
        <AlertMessage tone="error" title="申請を開けませんでした">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
        <LinkButton href="/staff">職員ホームへ戻る</LinkButton>
      </PageShell>
    );
  }

  const application = result.application;
  const updated = typeof query.updated === "string" ? query.updated : null;
  const success = updated && Object.hasOwn(UPDATED_MESSAGES, updated)
    ? UPDATED_MESSAGES[updated]
    : null;
  const queryError = typeof query.error === "string" ? query.error : null;
  const consent = application.has_consent
    ? await createGuardianConsentDownloadUrl(application.id)
    : { error: null, url: null };

  return (
    <PageShell
      title="地域活動の個人申請審査"
      description={application.original_application_id ? "継続申請" : "通常申請"}
    >
      {success && <AlertMessage tone="success" title={success} />}
      {queryError && (
        <AlertMessage tone="error" title="操作を完了できませんでした">
          <p>{errorMessage(queryError)}</p>
        </AlertMessage>
      )}
      <StatusRow>
        <StatusBadge kind="application" value={application.status} showKind />
        {application.charge && (
          <StatusBadge kind="payment" value={application.charge.payment_status} showKind />
        )}
        {application.stay && (
          <StatusBadge kind="stay" value={application.stay.status} showKind />
        )}
      </StatusRow>

      <section className={styles.panel} aria-labelledby="receipt-heading">
        <h2 id="receipt-heading">受付・利用情報</h2>
        <dl className={styles.facts}>
          <Fact label="受付番号">{application.reception_number || "未発行"}</Fact>
          <Fact label="利用期間">{formatPeriod(application.start_date, application.end_date)}</Fact>
          <Fact label="提出日時">
            {application.last_submitted_at
              ? formatJstDateTime(application.last_submitted_at)
              : "未提出"}
          </Fact>
          <Fact label="修正期限">
            {application.revision_due_at
              ? formatDeadline(application.revision_due_at)
              : "なし"}
          </Fact>
          {application.original_application_id && (
            <Fact label="申請区分">継続申請</Fact>
          )}
        </dl>
        {application.decision_reason && (
          <AlertMessage tone="warning" title="本人へ伝えた理由">
            <p>{application.decision_reason}</p>
          </AlertMessage>
        )}
      </section>

      <section className={styles.panel} aria-labelledby="applicant-heading">
        <h2 id="applicant-heading">申請者情報</h2>
        <dl className={styles.facts}>
          <Fact label="氏名">{application.user_name}</Fact>
          <Fact label="メールアドレス">{application.email_snapshot}</Fact>
          <Fact label="電話番号">{application.user_phone}</Fact>
          <Fact label="住所">{application.user_address}</Fact>
          <Fact label="緊急連絡先氏名">{application.emergency_name}</Fact>
          <Fact label="緊急連絡先電話">{application.emergency_phone}</Fact>
          <Fact label="緊急連絡先住所">{application.emergency_address}</Fact>
        </dl>
      </section>

      <section className={styles.panel} aria-labelledby="usage-heading">
        <h2 id="usage-heading">利用内容</h2>
        <dl className={styles.facts}>
          <Fact label="使用箇所">
            {Object.hasOwn(USAGE_PLACE_LABELS, application.usage_place)
              ? USAGE_PLACE_LABELS[application.usage_place]
              : "不明"}
          </Fact>
          <Fact label="使用目的">{application.purpose}</Fact>
          <Fact label="町内で行う活動">{application.local_activity}</Fact>
          <Fact label="特記事項">{application.special_notes || "なし"}</Fact>
          {application.extension_reason && (
            <Fact label="継続理由">{application.extension_reason}</Fact>
          )}
          <Fact label="保護者同意書">
            {application.requires_guardian_consent
              ? (application.has_consent ? "添付済み" : "未添付")
              : "添付不要"}
          </Fact>
        </dl>
        {application.has_consent && consent.url && (
          <LinkButton href={consent.url}>保護者同意書を開く</LinkButton>
        )}
        {application.has_consent && consent.error && (
          <AlertMessage tone="error" title="保護者同意書を開けませんでした">
            <p>{errorMessage(consent.error)}</p>
          </AlertMessage>
        )}
      </section>

      <ReviewOperations application={application} rooms={result.rooms} />

      <section className={styles.panel} aria-labelledby="payment-heading">
        <h2 id="payment-heading">料金・納付</h2>
        {application.charge ? (
          <>
            <dl className={styles.facts}>
              <Fact label="合計">{formatYen(application.charge.total_amount)}</Fact>
              <Fact label="納付期限">
                {application.charge.payment_due_date
                  ? formatJstDate(application.charge.payment_due_date)
                  : "未設定"}
              </Fact>
              <Fact label="納付確認日時">
                {application.charge.paid_at
                  ? formatJstDateTime(application.charge.paid_at)
                  : "未確認"}
              </Fact>
            </dl>
            <PaymentForm
              applicationId={application.id}
              updatedAt={application.updated_at}
              charge={application.charge}
            />
          </>
        ) : (
          <EmptyState title="料金はまだ確定していません" />
        )}
      </section>

      <section className={styles.panel} aria-labelledby="stay-heading">
        <h2 id="stay-heading">入退去</h2>
        {application.stay ? (
          <>
            <p>現在：{statusLabel("stay", application.stay.status)}</p>
            {application.stay.checked_in_at && (
              <p>入居日時：{formatJstDateTime(application.stay.checked_in_at)}</p>
            )}
            {application.stay.checked_out_at && (
              <p>退去日時：{formatJstDateTime(application.stay.checked_out_at)}</p>
            )}
            {application.status === "approved"
              && application.stay.status === "before_move_in" && (
              <StayOperationForm
                applicationId={application.id}
                updatedAt={application.updated_at}
                operation="check_in"
              />
            )}
            {application.status === "approved"
              && application.stay.status === "staying" && (
              <StayOperationForm
                applicationId={application.id}
                updatedAt={application.updated_at}
                operation="check_out"
              />
            )}
          </>
        ) : (
          <EmptyState title="滞在情報はまだありません" />
        )}
      </section>

      <section className={styles.panel} aria-labelledby="notes-heading">
        <h2 id="notes-heading">職員メモ</h2>
        {application.notes.length ? (
          <ol className={styles.history}>
            {application.notes.map((note) => (
              <li key={note.id}>
                <p>{note.body}</p>
                <time dateTime={note.updated_at}>{formatJstDateTime(note.updated_at)}</time>
              </li>
            ))}
          </ol>
        ) : (
          <EmptyState title="職員メモはありません" />
        )}
        <NoteForm applicationId={application.id} updatedAt={application.updated_at} />
      </section>

      <section className={styles.panel} aria-labelledby="account-heading">
        <h2 id="account-heading">アカウント停止</h2>
        {application.user_id === null || application.account_state === null ? (
          <AlertMessage tone="info" title="ログイン用アカウントとの紐付けはありません">
            <p>申請記録は管理記録として残り、新しく登録されたアカウントへ自動では結び付きません。</p>
          </AlertMessage>
        ) : application.account_state === "disabled" ? (
          <AlertMessage tone="info" title="このアカウントは停止済みです" />
        ) : application.account_state === "cleanup_pending" ? (
          <AlertMessage tone="info" title="このアカウントは初期化処理中です" />
        ) : ["rejected", "cancelled"].includes(application.status) ? (
          <AccountDisableForm applicationId={application.id} applicantName={application.user_name} />
        ) : (
          <p>不許可またはキャンセル済みの申請で、本人から町へ停止依頼があった場合に操作できます。</p>
        )}
      </section>

      <section className={styles.panel} aria-labelledby="history-heading">
        <h2 id="history-heading">申請状態の履歴</h2>
        {application.events.length ? (
          <ol className={styles.history}>
            {application.events.map((event, index) => (
              <li key={`${event.occurred_at}-${index}`}>
                <p>
                  {event.from_status
                    ? `${statusLabel("application", event.from_status)} → `
                    : ""}
                  <strong>{statusLabel("application", event.to_status)}</strong>
                </p>
                {event.public_reason && <p>{event.public_reason}</p>}
                <time dateTime={event.occurred_at}>
                  {formatJstDateTime(event.occurred_at)}
                </time>
              </li>
            ))}
          </ol>
        ) : (
          <EmptyState title="履歴はありません" />
        )}
      </section>

      <LinkButton href="/staff" fullWidthOnMobile>職員ホームへ戻る</LinkButton>
    </PageShell>
  );
}
