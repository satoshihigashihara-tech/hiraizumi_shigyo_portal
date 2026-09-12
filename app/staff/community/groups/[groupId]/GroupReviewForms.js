"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { statusLabel } from "@/app/components/status-labels";
import {
  approveCommunityGroupParticipantState,
  approveCommunityGroupState,
  cancelApprovedCommunityGroupParticipantState,
  confirmCommunityGroupCancellationState,
  confirmCommunityGroupPurposeState,
  rejectCommunityGroupParticipantState,
  rejectCommunityGroupState,
  requestCommunityGroupParticipantRevisionState,
  setCommunityGroupRoomsState,
  startCommunityGroupParticipantReviewState,
} from "@/app/actions/staff-groups";
import styles from "../groups.module.css";

function HiddenGroup({ group, applicationId }) {
  return (
    <>
      <input type="hidden" name="groupId" value={group.id} />
      {applicationId && <input type="hidden" name="applicationId" value={applicationId} />}
      <input type="hidden" name="updatedAt" value={group.updated_at} />
    </>
  );
}

function HiddenParticipant({ group, participant, useGroupVersion = false }) {
  return (
    <>
      <input type="hidden" name="groupId" value={group.id} />
      <input type="hidden" name="applicationId" value={participant.application_id} />
      <input type="hidden" name="updatedAt" value={useGroupVersion ? group.updated_at : participant.updated_at} />
    </>
  );
}

function FormError({ state }) {
  const ref = useRef(null);
  useEffect(() => {
    if (state?.error) ref.current?.focus();
  }, [state]);
  return state?.error ? (
    <p className={styles.formError} role="alert" tabIndex={-1} ref={ref}>{errorMessage(state.error)}</p>
  ) : null;
}

function ConfirmField({ id, state, label }) {
  return (
    <FormField
      as="checkbox"
      id={id}
      name="confirmed"
      label={label}
      required
      defaultChecked={state?.fields?.confirmed === "true"}
      error={state?.fieldErrors?.confirmed}
    />
  );
}

function PurposeForm({ group }) {
  const [state, action, pending] = useActionState(confirmCommunityGroupPurposeState, null);
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenGroup group={group} />
      <FormError state={state} />
      <p>団体の利用目的と町内で行う活動を確認してから、次の審査へ進めます。</p>
      <FormField as="textarea" id="purpose-note" name="reason" label="確認メモ（任意）" maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
      <SubmitButton pending={pending} pendingLabel="目的確認を保存中…">目的を確認済みにする</SubmitButton>
    </form>
  );
}

function RejectGroupForm({ group }) {
  const [state, action, pending] = useActionState(rejectCommunityGroupState, null);
  return (
    <form className={`${styles.operationForm} ${styles.dangerForm}`} action={action}>
      <HiddenGroup group={group} />
      <FormError state={state} />
      <p><strong>団体全体を不許可にします。</strong>未終了の参加者申請と部屋割りも終了します。</p>
      <FormField as="textarea" id="group-reject-reason" name="reason" label="不許可の理由" required maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
      <ConfirmField id="group-reject-confirmed" state={state} label="団体全体を不許可にすることを確認しました" />
      <SubmitButton variant="danger" pending={pending} pendingLabel="不許可を保存中…">団体を不許可にする</SubmitButton>
    </form>
  );
}

function ApproveGroupForm({ group, ready }) {
  const [state, action, pending] = useActionState(approveCommunityGroupState, null);
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenGroup group={group} />
      <FormError state={state} />
      <p>{ready ? "目的、全参加者、部屋別人数の確認が完了しています。" : "目的確認、全参加者の許可、人数と一致する部屋割りを完了してください。"}</p>
      <FormField as="textarea" id="group-approval-comment" name="reason" label="許可コメント（任意）" maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
      <ConfirmField id="group-approval-confirmed" state={state} label="団体の利用を許可することを確認しました" />
      <SubmitButton pending={pending} pendingLabel="許可を保存中…" disabled={!ready}>団体を許可する</SubmitButton>
    </form>
  );
}

function StartParticipantReviewForm({ group, participant }) {
  const [state, action, pending] = useActionState(startCommunityGroupParticipantReviewState, null);
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenParticipant group={group} participant={participant} />
      <FormError state={state} />
      <p>画面を開いただけでは審査中に変わりません。</p>
      <SubmitButton pending={pending} pendingLabel="審査を開始中…">この参加者の審査を開始</SubmitButton>
    </form>
  );
}

function ParticipantDecisionForms({ group, participant }) {
  const [revisionState, revisionAction, revisionPending] = useActionState(requestCommunityGroupParticipantRevisionState, null);
  const [rejectState, rejectAction, rejectPending] = useActionState(rejectCommunityGroupParticipantState, null);
  const [approveState, approveAction, approvePending] = useActionState(approveCommunityGroupParticipantState, null);
  const suffix = participant.application_id;
  return (
    <div className={styles.operationGrid}>
      <form className={styles.operationForm} action={revisionAction}>
        <HiddenParticipant group={group} participant={participant} />
        <FormError state={revisionState} />
        <h4>修正を依頼</h4>
        <FormField as="textarea" id={`participant-revision-reason-${suffix}`} name="reason" label="修正してほしい内容" required maxLength={2000} defaultValue={revisionState?.fields?.reason ?? ""} error={revisionState?.fieldErrors?.reason} />
        <FormField id={`participant-revision-deadline-${suffix}`} name="revisionDeadline" label="修正期限" type="datetime-local" required defaultValue={revisionState?.fields?.revisionDeadline ?? ""} error={revisionState?.fieldErrors?.revisionDeadline} />
        <SubmitButton pending={revisionPending} pendingLabel="修正依頼を保存中…">修正を依頼する</SubmitButton>
      </form>
      <form className={styles.operationForm} action={approveAction}>
        <HiddenParticipant group={group} participant={participant} />
        <FormError state={approveState} />
        <h4>参加者を許可</h4>
        <FormField as="textarea" id={`participant-approval-comment-${suffix}`} name="reason" label="許可コメント（任意）" maxLength={2000} defaultValue={approveState?.fields?.reason ?? ""} error={approveState?.fieldErrors?.reason} />
        <ConfirmField id={`participant-approve-confirmed-${suffix}`} state={approveState} label="この参加者の申請を許可することを確認しました" />
        <SubmitButton pending={approvePending} pendingLabel="許可を保存中…">参加者を許可する</SubmitButton>
      </form>
      <form className={`${styles.operationForm} ${styles.dangerForm}`} action={rejectAction}>
        <HiddenParticipant group={group} participant={participant} />
        <FormError state={rejectState} />
        <h4>参加者を不許可</h4>
        <FormField as="textarea" id={`participant-reject-reason-${suffix}`} name="reason" label="不許可の理由" required maxLength={2000} defaultValue={rejectState?.fields?.reason ?? ""} error={rejectState?.fieldErrors?.reason} />
        <FormField id={`participant-reject-deadline-${suffix}`} name="revisionDeadline" label="代表者の交代期限" type="datetime-local" required defaultValue={rejectState?.fields?.revisionDeadline ?? ""} error={rejectState?.fieldErrors?.revisionDeadline} />
        <ConfirmField id={`participant-reject-confirmed-${suffix}`} state={rejectState} label="この参加者を不許可にし、団体へ交代を求めることを確認しました" />
        <SubmitButton variant="danger" pending={rejectPending} pendingLabel="不許可を保存中…">参加者を不許可にする</SubmitButton>
      </form>
    </div>
  );
}

function initialRoomCounts(rooms, allocations, raw, clear = false) {
  const counts = Object.fromEntries(rooms.map((room) => [room.id, "0"]));
  if (clear) return counts;
  let source = allocations.filter((item) => item.released_from === null)
    .map((item) => ({ roomId: item.room_id, peopleCount: item.people_count }));
  if (raw) {
    try { const parsed = JSON.parse(raw); if (Array.isArray(parsed)) source = parsed; } catch {}
  }
  for (const item of source) {
    if (Object.hasOwn(counts, item.roomId)) counts[item.roomId] = String(item.peopleCount);
  }
  return counts;
}

function RoomPlanFields({ rooms, counts, setCounts, target, error, errorId }) {
  const plan = rooms.flatMap((room) => {
    const peopleCount = Number(counts[room.id]);
    return Number.isInteger(peopleCount) && peopleCount > 0 ? [{ roomId: room.id, peopleCount }] : [];
  });
  const total = plan.reduce((sum, item) => sum + item.peopleCount, 0);
  return (
    <>
      <input type="hidden" name="roomPlan" value={JSON.stringify(plan)} />
      <fieldset className={styles.roomFields} aria-describedby={error ? errorId : undefined}>
        <legend>部屋別人数</legend>
        <p className={styles.hint}>利用する部屋だけ1人以上を入力し、合計を対象人数と一致させてください。</p>
        <div className={styles.roomGrid}>
          {rooms.map((room) => (
            <label className={styles.roomField} key={room.id}>
              <span>{room.name}（定員{room.capacity}人）</span>
              <input type="number" min="0" max={room.capacity} step="1" value={counts[room.id]} onChange={(event) => setCounts((current) => ({ ...current, [room.id]: event.target.value }))} aria-label={`${room.name}の人数`} />
            </label>
          ))}
        </div>
      </fieldset>
      {error && <p id={errorId} className={styles.roomError} role="alert">{errorMessage(error)}</p>}
      <p className={`${styles.roomSummary} ${total !== target ? styles.roomMismatch : ""}`}>入力合計 {total}人 / 対象 {target}人</p>
    </>
  );
}

function RoomAllocationForm({ group }) {
  const [state, action, pending] = useActionState(setCommunityGroupRoomsState, null);
  const [counts, setCounts] = useState(() => initialRoomCounts(group.rooms, group.allocations, state?.fields?.roomPlan));
  const total = Object.values(counts).reduce((sum, value) => sum + (Number(value) || 0), 0);
  const target = group.participants.length;
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenGroup group={group} />
      <FormError state={state} />
      <RoomPlanFields rooms={group.rooms} counts={counts} setCounts={setCounts} target={target} error={state?.fieldErrors?.roomPlan} errorId="group-room-plan-error" />
      <FormField as="textarea" id="room-change-reason" name="reason" label={group.status === "approved" ? "変更理由" : "部屋割りメモ（任意）"} required={group.status === "approved"} maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
      <SubmitButton pending={pending} pendingLabel="部屋割りを保存中…" disabled={total !== target || target < 1}>部屋割りを保存する</SubmitButton>
    </form>
  );
}

function ApprovedParticipantCancellationForm({ group, participant }) {
  const [state, action, pending] = useActionState(cancelApprovedCommunityGroupParticipantState, null);
  const target = Math.max(0, group.participants.length - 1);
  const [counts, setCounts] = useState(() => initialRoomCounts(group.rooms, group.allocations, state?.fields?.roomPlan, target === 0));
  const total = Object.values(counts).reduce((sum, value) => sum + (Number(value) || 0), 0);
  const suffix = participant.application_id;
  return (
    <form className={`${styles.operationForm} ${styles.dangerForm}`} action={action}>
      <HiddenParticipant group={group} participant={participant} useGroupVersion />
      <FormError state={state} />
      <p><strong>許可済み参加者を減員します。</strong>滞在開始後は実行できません。</p>
      <FormField as="textarea" id={`participant-cancel-reason-${suffix}`} name="reason" label="減員の理由" required maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
      <RoomPlanFields rooms={group.rooms} counts={counts} setCounts={setCounts} target={target} error={state?.fieldErrors?.roomPlan} errorId={`participant-room-plan-error-${suffix}`} />
      <ConfirmField id={`participant-cancel-confirmed-${suffix}`} state={state} label="参加者を取消し、部屋別人数を変更することを確認しました" />
      <SubmitButton variant="danger" pending={pending} pendingLabel="減員を保存中…" disabled={total !== target}>許可済み参加者を取消す</SubmitButton>
    </form>
  );
}

function CancellationForm({ group, cancellation }) {
  const [state, action, pending] = useActionState(confirmCommunityGroupCancellationState, null);
  return (
    <form className={`${styles.operationForm} ${styles.dangerForm}`} action={action}>
      <HiddenGroup group={group} />
      <FormError state={state} />
      <p>代表者からの理由：{cancellation.cancel_reason || "理由なし"}</p>
      <p><strong>確定すると未終了の参加者申請、部屋割り、日程枠を終了します。</strong></p>
      <FormField as="textarea" id="group-cancellation-reason" name="reason" label="取消確定の理由" required maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
      <ConfirmField id="group-cancellation-confirmed" state={state} label="団体申請の取消を確定することを確認しました" />
      <SubmitButton variant="danger" pending={pending} pendingLabel="取消を確定中…">団体申請の取消を確定する</SubmitButton>
    </form>
  );
}

export function GroupReviewOperations({ group, cancellation }) {
  const purposeReady = Boolean(group.purpose_reviewed_at);
  const activeCount = group.participants.length;
  const approvedCount = group.participants.filter((participant) => participant.status === "approved").length;
  const allocatedCount = group.allocations.filter((item) => item.released_from === null).reduce((sum, item) => sum + item.people_count, 0);
  const readyToApprove = group.status === "under_review" && purposeReady && activeCount >= 2
    && activeCount === group.planned_participants && approvedCount === activeCount && allocatedCount === activeCount;
  return (
    <div className={styles.operations}>
      <section className={styles.panel} aria-labelledby="purpose-review-heading">
        <h2 id="purpose-review-heading">利用目的の確認</h2>
        {purposeReady ? <p>確認済みです。参加者審査へ進めます。</p> : group.status === "under_review" ? <PurposeForm group={group} /> : <p>現在の団体状態では目的確認を変更できません。</p>}
      </section>

      <section className={styles.panel} aria-labelledby="participant-review-heading">
        <h2 id="participant-review-heading">参加者の審査</h2>
        <p>{approvedCount}人許可 / {activeCount}人参加 / 予定{group.planned_participants}人</p>
        <ul className={styles.participantList}>
          {group.participants.map((participant) => (
            <li className={styles.participantCard} key={participant.application_id}>
              <div className={styles.participantHeader}>
                <h3>{participant.name || "氏名未入力"}</h3>
                <span>申請状態：{statusLabel("application", participant.status)}</span>
              </div>
              {!purposeReady ? <p>利用目的の確認後に審査できます。</p> : (
                <details className={styles.participantActions}>
                  <summary>この参加者を審査する</summary>
                  {group.status === "under_review" && participant.status === "submitted" && <StartParticipantReviewForm group={group} participant={participant} />}
                  {group.status === "under_review" && participant.status === "under_review" && <ParticipantDecisionForms group={group} participant={participant} />}
                  {group.status === "approved" && participant.status === "approved" && <ApprovedParticipantCancellationForm group={group} participant={participant} />}
                  {!((group.status === "under_review" && ["submitted", "under_review"].includes(participant.status)) || (group.status === "approved" && participant.status === "approved")) && <p>現在の状態では参加者の審査操作はできません。</p>}
                </details>
              )}
            </li>
          ))}
        </ul>
      </section>

      <section className={styles.panel} aria-labelledby="room-review-heading">
        <h2 id="room-review-heading">部屋別人数</h2>
        <p>割当済み {allocatedCount}人 / 参加者 {activeCount}人</p>
        {purposeReady && ["under_review", "approved"].includes(group.status) ? <RoomAllocationForm group={group} /> : <p>目的確認後の審査中または許可済みの団体で変更できます。</p>}
      </section>

      {group.status === "under_review" && (
        <section className={styles.panel} aria-labelledby="group-decision-heading">
          <h2 id="group-decision-heading">団体の最終判断</h2>
          <div className={styles.operationGrid}>
            <ApproveGroupForm group={group} ready={readyToApprove} />
            <RejectGroupForm group={group} />
          </div>
        </section>
      )}

      {cancellation?.can_confirm && (
        <section className={styles.panel} aria-labelledby="group-cancellation-heading">
          <h2 id="group-cancellation-heading">団体の取消申請</h2>
          <CancellationForm group={group} cancellation={cancellation} />
        </section>
      )}
    </div>
  );
}
