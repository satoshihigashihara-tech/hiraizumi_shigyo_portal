"use client";

import { useActionState, useEffect, useRef } from "react";
import { requestCommunityGroupCancellation } from "@/app/actions/community-groups";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../groups.module.css";

async function requestCancellation(_previousState, formData) {
  return requestCommunityGroupCancellation(formData);
}

export default function GroupCancellationForm({ groupId, updatedAt }) {
  const [state, formAction, pending] = useActionState(requestCancellation, null);
  const summaryRef = useRef(null);

  useEffect(() => {
    if (!state?.error) return;
    const target = state.fieldErrors?.reason ? document.getElementById("group-cancellation-reason")
      : state.fieldErrors?.confirmed ? document.getElementById("group-cancellation-confirmed") : summaryRef.current;
    target?.focus();
  }, [state]);

  return (
    <section className={`${styles.panel} ${styles.dangerPanel}`} aria-labelledby="group-cancellation-heading">
      <h2 id="group-cancellation-heading">団体申請の取消</h2>
      <p className={styles.note}>取消申請後は、新しい参加者を招待できません。町の職員が確認するまで利用枠は保持されます。</p>

      <form className={styles.operationForm} action={formAction} noValidate>
        <input type="hidden" name="groupId" value={groupId} />
        <input type="hidden" name="updatedAt" value={updatedAt} />

        {state?.error && (
          <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
            <AlertMessage tone="error" title="団体の取消を申請できませんでした">
              <p>{errorMessage(state.error)}</p>
            </AlertMessage>
          </div>
        )}

        <FormField as="textarea" id="group-cancellation-reason" name="reason" label="取消理由" required
          rows={4} maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
        <FormField as="checkbox" id="group-cancellation-confirmed" name="confirmed"
          label="団体全体の取消を申請することを確認しました" required error={state?.fieldErrors?.confirmed} />
        <div className={styles.actions}>
          <SubmitButton variant="danger" pending={pending} pendingLabel="申請中…" fullWidthOnMobile>
            団体の取消を申請する
          </SubmitButton>
        </div>
      </form>
    </section>
  );
}
