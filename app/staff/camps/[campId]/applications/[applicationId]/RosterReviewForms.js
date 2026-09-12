"use client";
import { useActionState } from "react";
import { reviewCampRosterState } from "@/app/actions/staff-camp-review";
import { endCampRosterParticipationState } from "@/app/actions/staff-camp-lifecycle";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { campReviewMessage } from "@/utils/staff-camps/review-messages";
import styles from "./page.module.css";

export function RosterReviewForm({ review, operation }) {
  const [state, action, pending] = useActionState(reviewCampRosterState, null);
  const label = { start_review: "審査を開始", request_revision: "修正を依頼", approve: review.previously_approved ? "再許可する" : "申請を許可" }[operation];
  return <form action={action} className={styles.operationForm}>
    {Object.entries({ campId: review.camp_id, applicationId: review.application_id, updatedAt: review.updated_at,
      roomPlanVersion: review.room_plan_version, assignmentVersion: review.assignment_version, submittedVersionId: review.submitted_version_id,
      reviewAction: operation }).map(([name, value]) => <input key={name} type="hidden" name={name} value={value} />)}
    {state?.error && <AlertMessage tone="error" title="操作できませんでした"><p>{campReviewMessage(state.error)}</p></AlertMessage>}
    {state?.saved && <AlertMessage tone="success" title="審査結果を保存しました" />}
    {operation !== "start_review" && <FormField id={`roster-${operation}-reason`} name="reason" label={operation === "request_revision" ? "修正してほしい内容" : "許可コメント"} as="textarea" maxLength={2000} required={operation === "request_revision"} defaultValue={state?.fields?.reason || ""} />}
    <SubmitButton pending={pending} disabled={state?.saved}>{label}</SubmitButton>
  </form>;
}
export function RosterRejectForm({ lifecycle: l }) {
  const [state, action, pending] = useActionState(endCampRosterParticipationState, null);
  return <form action={action} className={styles.operationForm}>
    {Object.entries({ campId: l.camp_id, eligibleUserId: l.eligible_user_id, updatedAt: l.updated_at, rosterVersion: l.roster_version,
      roomPlanVersion: l.room_plan_version, applicationId: l.application_id, applicationUpdatedAt: l.application_updated_at,
      endAction: "reject" }).map(([name, value]) => <input key={name} type="hidden" name={name} value={value} />)}
    {state?.error && <AlertMessage tone="error" title="不許可にできませんでした"><p>{campReviewMessage(state.error)}</p></AlertMessage>}
    {state?.saved && <AlertMessage tone="success" title="不許可と参加終了を記録しました" />}
    <p>不許可にすると今回の参加を終了し、部屋の割当を解放します。過去の許可・料金・納付・PDFは記録として残ります。</p>
    <FormField id="roster-reject-reason" name="reason" label="不許可の理由（本人へ表示）" as="textarea" required maxLength={2000} defaultValue={state?.fields?.reason || ""} />
    <FormField id="roster-reject-confirm" name="confirmed" as="checkbox" value="yes" required label="不許可と参加終了の対象者を確認しました" />
    <SubmitButton pending={pending} disabled={state?.saved} variant="danger">不許可にする</SubmitButton>
  </form>;
}
