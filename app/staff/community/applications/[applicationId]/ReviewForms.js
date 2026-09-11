"use client";

import { useActionState } from "react";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import {
  approveCommunityApplicationState,
  assignCommunityApplicationRoomState,
  confirmCommunityApplicationCancellationState,
  rejectCommunityApplicationState,
  requestCommunityApplicationRevisionState,
  startCommunityApplicationReviewState,
} from "@/app/actions/staff-community-applications";
import styles from "./page.module.css";

function HiddenVersion({ application }) {
  return (
    <>
      <input type="hidden" name="applicationId" value={application.id} />
      <input type="hidden" name="updatedAt" value={application.updated_at} />
    </>
  );
}

function FormError({ state }) {
  return state?.error ? (
    <p className={styles.formError} role="alert">{errorMessage(state.error)}</p>
  ) : null;
}

function StartReviewForm({ application }) {
  const [state, action, pending] = useActionState(
    startCommunityApplicationReviewState,
    null,
  );
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenVersion application={application} />
      <FormError state={state} />
      <p>画面を開いただけでは審査状態を変更しません。</p>
      <SubmitButton pending={pending} pendingLabel="審査を開始中…">
        審査を開始
      </SubmitButton>
    </form>
  );
}

function RevisionForm({ application }) {
  const [state, action, pending] = useActionState(
    requestCommunityApplicationRevisionState,
    null,
  );
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenVersion application={application} />
      <FormError state={state} />
      <FormField
        as="textarea"
        id="revisionReason"
        name="reason"
        label="修正してほしい内容"
        required
        maxLength={2000}
        defaultValue={state?.fields?.reason ?? ""}
        error={state?.fieldErrors?.reason}
      />
      <FormField
        id="revisionDeadline"
        name="revisionDeadline"
        label="修正期限"
        type="datetime-local"
        hint="空欄の場合は期限を設定しません。"
        defaultValue={state?.fields?.revisionDeadline ?? ""}
        error={state?.fieldErrors?.revisionDeadline}
      />
      <SubmitButton pending={pending} pendingLabel="修正を依頼中…">
        修正を依頼
      </SubmitButton>
    </form>
  );
}

function RejectForm({ application }) {
  const [state, action, pending] = useActionState(
    rejectCommunityApplicationState,
    null,
  );
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenVersion application={application} />
      <FormError state={state} />
      <FormField
        as="textarea"
        id="rejectReason"
        name="reason"
        label="不許可の理由"
        required
        maxLength={2000}
        defaultValue={state?.fields?.reason ?? ""}
        error={state?.fieldErrors?.reason}
      />
      <SubmitButton variant="danger" pending={pending} pendingLabel="不許可を保存中…">
        不許可にする
      </SubmitButton>
    </form>
  );
}

function RoomForm({ application, rooms }) {
  const [state, action, pending] = useActionState(
    assignCommunityApplicationRoomState,
    null,
  );
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenVersion application={application} />
      <FormError state={state} />
      <FormField
        as="select"
        id="roomId"
        name="roomId"
        label="部屋"
        required
        defaultValue={state?.fields?.roomId ?? application.room_allocation?.room_id ?? ""}
        error={state?.fieldErrors?.roomId}
        options={[
          { value: "", label: "部屋を選択" },
          ...rooms.map((room) => ({
            value: room.id,
            label: `${room.name}（定員${room.capacity}人）`,
          })),
        ]}
      />
      <FormField
        as="textarea"
        id="roomReason"
        name="reason"
        label="変更理由（変更時）"
        maxLength={2000}
        defaultValue={state?.fields?.reason ?? ""}
        error={state?.fieldErrors?.reason}
      />
      <SubmitButton pending={pending} pendingLabel="部屋割りを保存中…">
        部屋割りを保存
      </SubmitButton>
    </form>
  );
}

function ApproveForm({ application }) {
  const [state, action, pending] = useActionState(
    approveCommunityApplicationState,
    null,
  );
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenVersion application={application} />
      <FormError state={state} />
      <FormField
        as="textarea"
        id="approvalComment"
        name="approvalComment"
        label="許可コメント"
        maxLength={2000}
        defaultValue={state?.fields?.approvalComment ?? application.approval_comment ?? ""}
        error={state?.fieldErrors?.approvalComment}
      />
      <SubmitButton variant="primary" pending={pending} pendingLabel="許可を保存中…">
        申請を許可
      </SubmitButton>
    </form>
  );
}

function CancellationForm({ application }) {
  const [state, action, pending] = useActionState(
    confirmCommunityApplicationCancellationState,
    null,
  );
  return (
    <form className={styles.operationForm} action={action}>
      <HiddenVersion application={application} />
      <FormError state={state} />
      <FormField
        as="textarea"
        id="cancellationReason"
        name="reason"
        label="キャンセル確定の理由"
        required
        maxLength={2000}
        defaultValue={state?.fields?.reason ?? ""}
        error={state?.fieldErrors?.reason}
      />
      <SubmitButton variant="danger" pending={pending} pendingLabel="キャンセルを確定中…">
        キャンセルを確定
      </SubmitButton>
    </form>
  );
}

export function ReviewOperations({ application, rooms }) {
  const canReview = application.status === "submitted";
  const canDecide = application.status === "under_review";
  const canAssignRoom = ["under_review", "approved"].includes(application.status);

  return (
    <>
      <section className={styles.panel} aria-labelledby="review-heading">
        <h2 id="review-heading">審査</h2>
        {canReview && <StartReviewForm application={application} />}
        {canDecide && (
          <div className={styles.operationGrid}>
            <RevisionForm application={application} />
            <RejectForm application={application} />
          </div>
        )}
        {!canReview && !canDecide && (
          <p>現在の状態では審査状態を変更できません。</p>
        )}
      </section>

      <section className={styles.panel} aria-labelledby="room-heading">
        <h2 id="room-heading">部屋割り・許可</h2>
        {application.room_allocation ? (
          <p>現在の部屋：<strong>{application.room_allocation.room_name}</strong></p>
        ) : (
          <p>部屋はまだ割り当てられていません。</p>
        )}
        {canAssignRoom && <RoomForm application={application} rooms={rooms} />}
        {canDecide && <ApproveForm application={application} />}
        {!canAssignRoom && !canDecide && (
          <p>現在の状態では部屋割りや許可を変更できません。</p>
        )}
      </section>

      {application.status === "cancellation_requested" && (
        <section className={styles.panel} aria-labelledby="cancellation-heading">
          <h2 id="cancellation-heading">キャンセル申請</h2>
          <p>本人からの理由：{application.cancel_reason || "理由なし"}</p>
          <p>確定すると申請枠と部屋割りが解放されます。</p>
          <CancellationForm application={application} />
        </section>
      )}
    </>
  );
}
