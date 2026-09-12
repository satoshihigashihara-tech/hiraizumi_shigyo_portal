import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import SubmitButton from "@/app/components/SubmitButton";
import { formatDeadline, formatJstDate, formatJstDateTime, formatPeriod, formatYen } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { ROOM_PREFERENCE_LABELS, USAGE_PLACE_LABELS, statusLabel } from "@/app/components/status-labels";
import { approveCampApplication, assignCampApplicationRoom, rejectCampApplication,
  requestCampApplicationRevision, startCampApplicationReview } from "@/app/actions/staff-applications";
import { getStaffCampApplicationDetail } from "@/utils/application-operations/queries";
import { AccountDisableForm, NoteForm, PaymentForm, StayOperationForm } from "./OperationForms";
import styles from "./page.module.css";

export const metadata = { title: "キャンプ申請審査｜ひらいずみ志業ポータル" };

const UPDATED_MESSAGES = {
  under_review: "審査を開始しました。", revision_requested: "修正を依頼しました。",
  rejected: "申請を不許可にしました。", approved: "申請を許可しました。",
  "room-assigned": "部屋割りを保存しました。", "payment-updated": "納付情報を保存しました。",
  "checked-in": "入居を記録しました。", "checked-out": "退去を記録しました。",
  "note-saved": "職員メモを保存しました。",
  "account-disabled": "利用者のアカウントを停止しました。",
};

function HiddenVersion({ application }) {
  return <><input type="hidden" name="applicationId" value={application.id} /><input type="hidden" name="updatedAt" value={application.updated_at} /></>;
}

function Fact({ label, children }) { return <div><dt>{label}</dt><dd>{children || "未設定"}</dd></div>; }

export default async function StaffCampApplicationPage({ params, searchParams }) {
  const [{ campId, applicationId }, query] = await Promise.all([params, searchParams]);
  const result = await getStaffCampApplicationDetail(campId, applicationId);
  if (result.error === "not-found") notFound();
  if (result.error || !result.application) return <PageShell title="キャンプ申請審査"><AlertMessage tone="error" title="申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/staff">職員ホームへ戻る</LinkButton></PageShell>;
  const a = result.application;
  const success = typeof query.updated === "string" ? UPDATED_MESSAGES[query.updated] : null;
  const queryError = typeof query.error === "string" ? query.error : null;
  const canReview = a.status === "submitted";
  const canDecide = a.status === "under_review";
  const canAssignRoom = ["under_review", "approved"].includes(a.status);

  return <PageShell title="キャンプ申請審査" description={a.camp_name}>
    {success && <AlertMessage tone="success" title={success} />}
    {queryError && <AlertMessage tone="error" title="操作を完了できませんでした"><p>{errorMessage(queryError)}</p></AlertMessage>}
    <StatusRow><StatusBadge kind="application" value={a.status} showKind />
      {a.charge && <StatusBadge kind="payment" value={a.charge.payment_status} showKind />}
      {a.stay && <StatusBadge kind="stay" value={a.stay.status} showKind />}</StatusRow>

    <section className={styles.panel}><h2>受付・利用情報</h2><dl className={styles.facts}>
      <Fact label="受付番号">{a.reception_number || "未発行"}</Fact><Fact label="利用期間">{formatPeriod(a.start_date, a.end_date)}</Fact>
      <Fact label="提出日時">{a.last_submitted_at ? formatJstDateTime(a.last_submitted_at) : "未提出"}</Fact>
      <Fact label="修正期限">{a.revision_due_at ? formatDeadline(a.revision_due_at) : "なし"}</Fact>
    </dl>{a.decision_reason && <AlertMessage tone="warning" title="本人へ伝えた理由"><p>{a.decision_reason}</p></AlertMessage>}</section>

    <section className={styles.panel}><h2>申請者情報</h2><dl className={styles.facts}>
      <Fact label="氏名">{a.user_name}</Fact><Fact label="メールアドレス">{a.email_snapshot}</Fact><Fact label="電話番号">{a.user_phone}</Fact><Fact label="住所">{a.user_address}</Fact>
      <Fact label="緊急連絡先氏名">{a.emergency_name}</Fact><Fact label="緊急連絡先電話">{a.emergency_phone}</Fact><Fact label="緊急連絡先住所">{a.emergency_address}</Fact>
    </dl></section>

    <section className={styles.panel}><h2>利用内容</h2><dl className={styles.facts}>
      <Fact label="使用箇所">{USAGE_PLACE_LABELS[a.usage_place] || "不明"}</Fact><Fact label="部屋の希望">{ROOM_PREFERENCE_LABELS[a.room_preference] || "不明"}</Fact>
      <Fact label="使用目的">{a.purpose}</Fact><Fact label="町内で行う活動">{a.local_activity}</Fact><Fact label="特記事項">{a.special_notes || "なし"}</Fact>
      <Fact label="保護者同意書">{a.requires_guardian_consent ? (a.has_consent ? "添付済み" : "未添付") : "添付不要"}</Fact>
    </dl></section>

    <section className={styles.panel}><h2>審査</h2>
      {canReview && <form className={styles.operationForm} action={startCampApplicationReview}><HiddenVersion application={a} /><p>画面を開いただけでは審査状態を変更しません。</p><SubmitButton>審査を開始</SubmitButton></form>}
      {canDecide && <div className={styles.operationGrid}>
        <form className={styles.operationForm} action={requestCampApplicationRevision}><HiddenVersion application={a} /><FormField id="revisionReason" name="reason" label="修正してほしい内容" as="textarea" required maxLength={2000} /><SubmitButton>修正を依頼</SubmitButton></form>
        <form className={styles.operationForm} action={rejectCampApplication}><HiddenVersion application={a} /><FormField id="rejectReason" name="reason" label="不許可の理由" as="textarea" required maxLength={2000} /><SubmitButton variant="danger">不許可にする</SubmitButton></form>
      </div>}
      {!canReview && !canDecide && <p>現在の状態（{statusLabel("application", a.status)}）では審査状態を変更できません。</p>}
    </section>

    <section className={styles.panel}><h2>部屋割り・許可</h2>
      {a.room_allocation ? <p>現在の部屋：<strong>{a.room_allocation.room_name}</strong>（{formatPeriod(a.room_allocation.start_date, a.room_allocation.end_date)}）</p> : <EmptyState title="部屋は未割当です" />}
      {canAssignRoom && <form className={styles.operationForm} action={assignCampApplicationRoom}><HiddenVersion application={a} />
        <FormField as="select" id="roomId" name="roomId" label="部屋" required defaultValue={a.room_allocation?.room_id || ""} options={[{ value: "", label: "部屋を選択" }, ...result.rooms.map((room) => ({ value: room.id, label: `${room.name}（定員${room.capacity}人）` }))]} />
        <FormField id="roomReason" name="reason" label="変更理由（変更時）" as="textarea" maxLength={2000} /><SubmitButton>部屋割りを保存</SubmitButton></form>}
      {canDecide && <form className={styles.operationForm} action={approveCampApplication}><HiddenVersion application={a} /><FormField id="approvalComment" name="approvalComment" label="許可コメント" as="textarea" maxLength={2000} /><SubmitButton variant="primary">申請を許可</SubmitButton></form>}
    </section>

    <section className={styles.panel}><h2>料金・納付</h2>{a.charge ? <><dl className={styles.facts}><Fact label="合計">{formatYen(a.charge.total_amount)}</Fact><Fact label="納付期限">{a.charge.payment_due_date ? formatJstDate(a.charge.payment_due_date) : "未設定"}</Fact><Fact label="納付確認日時">{a.charge.paid_at ? formatJstDateTime(a.charge.paid_at) : "未確認"}</Fact></dl><PaymentForm applicationId={a.id} updatedAt={a.updated_at} charge={a.charge} /></> : <EmptyState title="料金はまだ確定していません" />}</section>

    <section className={styles.panel}><h2>入退去</h2>{a.stay ? <><p>現在：{statusLabel("stay", a.stay.status)}</p>{a.stay.checked_in_at && <p>入居日時：{formatJstDateTime(a.stay.checked_in_at)}</p>}{a.stay.checked_out_at && <p>退去日時：{formatJstDateTime(a.stay.checked_out_at)}</p>}{a.status === "approved" && a.stay.status === "before_move_in" && <StayOperationForm applicationId={a.id} updatedAt={a.updated_at} operation="check_in" />}{a.status === "approved" && a.stay.status === "staying" && <StayOperationForm applicationId={a.id} updatedAt={a.updated_at} operation="check_out" />}</> : <EmptyState title="滞在情報はまだありません" />}</section>

    <section className={styles.panel}><h2>職員メモ</h2>{a.notes.length ? <ol className={styles.history}>{a.notes.map((note) => <li key={note.id}><p>{note.body}</p><time dateTime={note.updated_at}>{formatJstDateTime(note.updated_at)}</time></li>)}</ol> : <EmptyState title="職員メモはありません" />}<NoteForm applicationId={a.id} updatedAt={a.updated_at} /></section>

    <section className={styles.panel}><h2>アカウント停止</h2>
      {a.user_id === null || a.account_state === null
        ? <AlertMessage tone="info" title="ログイン用アカウントとの紐付けはありません"><p>申請記録は管理記録として残り、新しく登録されたアカウントへ自動では結び付きません。</p></AlertMessage>
        : a.account_state === "disabled"
          ? <AlertMessage tone="info" title="このアカウントは停止済みです" />
          : a.account_state === "cleanup_pending"
            ? <AlertMessage tone="info" title="このアカウントは初期化処理中です" />
            : ["rejected", "cancelled"].includes(a.status)
              ? <AccountDisableForm applicationId={a.id} applicantName={a.user_name} />
              : <p>不許可またはキャンセル済みの申請で、本人から町へ停止依頼があった場合に操作できます。</p>}
    </section>

    <section className={styles.panel}><h2>申請状態の履歴</h2>{a.events.length ? <ol className={styles.history}>{a.events.map((event, index) => <li key={`${event.occurred_at}-${index}`}><p>{event.from_status ? `${statusLabel("application", event.from_status)} → ` : ""}<strong>{statusLabel("application", event.to_status)}</strong></p>{event.public_reason && <p>{event.public_reason}</p>}<time dateTime={event.occurred_at}>{formatJstDateTime(event.occurred_at)}</time></li>)}</ol> : <EmptyState title="履歴はありません" />}</section>
    <LinkButton href="/staff" fullWidthOnMobile>職員ホームへ戻る</LinkButton>
  </PageShell>;
}
