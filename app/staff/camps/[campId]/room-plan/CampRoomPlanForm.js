"use client";

import { useActionState, useEffect, useMemo, useRef, useState } from "react";
import { saveCampRoomPlanState } from "@/app/actions/staff-camp-room-plans";
import AlertMessage from "@/app/components/AlertMessage";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../../camps.module.css";

const INITIAL = { error: null, fields: null, saved: false };

function initialAssignments(plan) {
  return Object.fromEntries(plan.users.map((user) => [user.id, user.roomId ?? ""]));
}

export default function CampRoomPlanForm({ plan }) {
  const [state, action, pending] = useActionState(saveCampRoomPlanState, INITIAL);
  const [assignments, setAssignments] = useState(() => initialAssignments(plan));
  const errorRef = useRef(null);

  useEffect(() => {
    if (state?.error) errorRef.current?.focus();
  }, [state?.error]);
  const counts = useMemo(() => Object.fromEntries(plan.rooms.map((room) => [room.id,
    plan.users.filter((user) => assignments[user.id] === room.id).length])), [assignments, plan.rooms, plan.users]);
  const unassigned = plan.users.filter((user) => !assignments[user.id]);
  const overCapacity = plan.rooms.filter((room) => counts[room.id] > room.capacity);
  const stale = !state?.saved && plan.savedRosterVersion !== plan.rosterVersion;
  const canSave = plan.rooms.length > 0 && unassigned.length === 0 && overCapacity.length === 0 && !pending;
  const payload = JSON.stringify(plan.users.map((user) => ({ eligible_user_id: user.id, room_id: assignments[user.id] })).filter((row) => row.room_id));

  return <form className={styles.roomPlan} action={action}>
    <input type="hidden" name="campId" value={plan.campId} /><input type="hidden" name="rosterVersion" value={plan.rosterVersion} />
    <input type="hidden" name="roomPlanVersion" value={state?.fields?.roomPlanVersion ?? plan.roomPlanVersion} /><input type="hidden" name="assignments" value={payload} />
    {state?.error && <div ref={errorRef} tabIndex={-1} className={styles.errorFocus}><AlertMessage tone="error" title="部屋割りを保存できませんでした"><p>{errorMessage(state.error)}</p>{state.error === "stale-update" && <p>対象者名簿または部屋割りが更新されています。画面を再読み込みして内容を確認してください。</p>}</AlertMessage></div>}
    {state?.saved && !state?.error && <AlertMessage tone="success" title="事前部屋割りを保存しました"><p>名簿バージョン {plan.rosterVersion} の部屋割りを保存しました。</p></AlertMessage>}
    {stale && <AlertMessage tone="warning" title="名簿が更新されています"><p>保存済みの部屋割りは現在の対象者名簿より古い状態です。全員の割当を確認して保存してください。</p></AlertMessage>}
    {plan.rooms.length === 0 && <AlertMessage tone="warning" title="確認済みの部屋がありません"><p>利用可能な部屋が確認されるまで部屋割りは保存できません。</p></AlertMessage>}
    <section className={styles.roomPlanSummary} aria-label="部屋割りの確認状況"><p><strong>{plan.users.length}人</strong>の参加対象者</p><p className={unassigned.length ? styles.roomPlanWarning : ""}>未配置 <strong>{unassigned.length}人</strong></p><p className={overCapacity.length ? styles.roomPlanWarning : ""}>定員超過 <strong>{overCapacity.length}室</strong></p></section>
    <section aria-labelledby="room-plan-rooms"><h2 id="room-plan-rooms" className={styles.sectionTitle}>部屋の利用状況</h2><ul className={styles.roomList}>{plan.rooms.map((room) => <li key={room.id} className={counts[room.id] > room.capacity ? styles.roomOver : ""}><strong>{room.name}</strong><span>{counts[room.id]} / {room.capacity}人</span>{counts[room.id] > room.capacity && <span>定員を超えています</span>}</li>)}</ul></section>
    <fieldset className={styles.roomAssignments}><legend>参加対象者ごとの部屋</legend><p>各対象者に部屋を1つ選択してください。キーボードではTabで移動し、上下矢印で選択できます。</p>
      <div className={styles.assignmentList}>{plan.users.map((user) => <label key={user.id} className={styles.assignmentRow}><span>{user.managementName || "管理用氏名未登録"}</span><select value={assignments[user.id]} onChange={(event) => setAssignments((current) => ({ ...current, [user.id]: event.target.value }))} aria-label={`${user.managementName || "管理用氏名未登録"}の部屋`} disabled={pending}><option value="">部屋を選択</option>{plan.rooms.map((room) => <option key={room.id} value={room.id}>{room.name}（定員{room.capacity}人）</option>)}</select></label>)}</div>
    </fieldset>
    <SubmitButton pending={pending} pendingLabel="保存中…" disabled={!canSave} fullWidthOnMobile>事前部屋割りを保存する</SubmitButton>
    {!canSave && !pending && <p className={styles.roomPlanHelp} aria-live="polite">{plan.rooms.length === 0 ? "確認済みの部屋が必要です。" : unassigned.length ? `未配置の対象者が${unassigned.length}人います。` : "定員超過を解消してください。"}</p>}
  </form>;
}
