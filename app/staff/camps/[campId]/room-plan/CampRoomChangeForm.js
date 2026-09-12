"use client";
import { useActionState, useState } from "react";
import { changeCampRoomsState } from "@/app/actions/staff-camp-review";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { campReviewMessage } from "@/utils/staff-camps/review-messages";
import { formatDeadline } from "@/app/components/format";
import styles from "../../camps.module.css";

export default function CampRoomChangeForm({ context }) {
  const [state, action, pending] = useActionState(changeCampRoomsState, null);
  const [rooms, setRooms] = useState(() => Object.fromEntries(context.users.map((u) => [u.id, u.roomId || ""])));
  const changed = context.users.filter((u) => rooms[u.id] && rooms[u.id] !== u.roomId);
  const revisions = changed.filter((u) => ["submitted", "under_review", "revision_requested", "approved"].includes(u.status));
  const invalid = context.users.some((u) => !rooms[u.id]) || context.rooms.some((r) => context.users.filter((u) => rooms[u.id] === r.id).length > r.capacity);
  return <form className={styles.roomPlan} action={action}>
    <h2>部屋変更と修正依頼</h2>
    <p>変更された提出済みの申請は、本人の再提出と職員の再審査が必要です。修正期限はキャンプ開始前までの範囲で設定されます。入居前・キャンプ開始前に操作できます。</p>
    <input type="hidden" name="campId" value={context.campId} /><input type="hidden" name="rosterVersion" value={context.rosterVersion} />
    <input type="hidden" name="roomPlanVersion" value={context.roomPlanVersion} /><input type="hidden" name="participants" value={JSON.stringify(context.expectations)} />
    <input type="hidden" name="assignments" value={JSON.stringify(context.users.map((u) => ({ eligible_user_id: u.id, room_id: rooms[u.id] })))} />
    {state?.error && <AlertMessage tone="error" title="変更を保存できませんでした"><p>{campReviewMessage(state.error)}</p></AlertMessage>}
    {state?.saved && <AlertMessage tone="success" title="部屋変更を保存しました"><p>{state.revisedCount}件の申請を修正依頼にしました。最新の配置を確認するには画面を再読み込みしてください。</p></AlertMessage>}
    {!context.canChange && <AlertMessage tone="warning" title="現在は部屋を変更できません"><p>キャンプ開始後または入退去記録がある場合は変更できません。</p></AlertMessage>}
    <fieldset disabled={pending || state?.saved || !context.canChange} className={styles.roomAssignments}><legend>変更後の全員の部屋</legend>
      {context.users.map((u) => <label className={styles.assignmentRow} key={u.id}><span>{u.name || "氏名未登録"}（現在：{context.rooms.find((r) => r.id === u.roomId)?.name || "未配置"}）</span>
        <select aria-label={`${u.name || "氏名未登録"}の変更後の部屋`} value={rooms[u.id]} onChange={(e) => setRooms({ ...rooms, [u.id]: e.target.value })}><option value="">部屋を選択</option>{context.rooms.map((r) => <option key={r.id} value={r.id}>{r.name}（定員{r.capacity}人）</option>)}</select></label>)}
      <p aria-live="polite">修正依頼の対象：{revisions.length ? revisions.map((u) => u.name || "氏名未登録").join("、") : "なし"}</p>
      {revisions.length > 0 && <ul>{revisions.map((u) => <li key={u.id}>{u.name || "氏名未登録"}の修正期限：{formatDeadline(u.status === "revision_requested" ? u.revisionDueAt : context.proposedRevisionDueAt)}</li>)}</ul>}
      <FormField id="room-change-reason" name="reason" label="変更理由（修正依頼の本人にも表示）" as="textarea" required maxLength={2000} defaultValue={state?.fields?.reason || ""} />
      <FormField id="room-change-confirmed" name="confirmed" as="checkbox" value="yes" required label="変更前後と修正依頼の対象者を確認しました" />
      <SubmitButton pending={pending} disabled={invalid || changed.length === 0}>部屋変更と修正依頼を保存</SubmitButton>
      {invalid && <p>全員に部屋を割り当て、定員以内にしてください。</p>}
    </fieldset>
  </form>;
}
