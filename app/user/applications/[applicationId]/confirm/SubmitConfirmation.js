"use client";

import { useState } from "react";
import { submitCampApplication } from "@/app/actions/camp-applications";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import styles from "../application-view.module.css";

export default function SubmitConfirmation({ applicationId }) {
  const [confirmed, setConfirmed] = useState(false);

  return (
    <form className={styles.submissionPanel} action={submitCampApplication}>
      <input type="hidden" name="applicationId" value={applicationId} />
      <label className={styles.confirmationLabel}>
        <input
          type="checkbox"
          name="confirmed"
          value="true"
          checked={confirmed}
          onChange={(event) => setConfirmed(event.target.checked)}
          required
        />
        <span>入力内容を確認し、申請を提出します</span>
      </label>
      <p className={styles.submissionNote}>
        提出後は職員が内容を審査します。この操作だけでは利用は確定しません。
      </p>
      <div className={styles.actions}>
        <LinkButton
          href={`/user/applications/${applicationId}/edit`}
          variant="secondary"
          fullWidthOnMobile
        >
          入力へ戻る
        </LinkButton>
        <SubmitButton
          disabled={!confirmed}
          pendingLabel="提出中…"
          fullWidthOnMobile
        >
          申請を提出する
        </SubmitButton>
      </div>
    </form>
  );
}
