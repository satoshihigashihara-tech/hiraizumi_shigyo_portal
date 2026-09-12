"use client";

import { useActionState } from 'react';
import { generateStaffCampRoomPlanPdfState } from '@/app/actions/staff-camp-room-plans';
import AlertMessage from '@/app/components/AlertMessage';
import LinkButton from '@/app/components/LinkButton';
import SubmitButton from '@/app/components/SubmitButton';
import { errorMessage } from '@/app/components/messages';
import styles from '../../camps.module.css';

export default function CampRoomPlanPdf({ pdf }) {
  const [state, action, pending] = useActionState(generateStaffCampRoomPlanPdfState, { error: null });
  return <section className={styles.card} aria-labelledby="room-plan-pdf-title">
    <h2 id="room-plan-pdf-title">職員用配置表PDF</h2>
    <p>最新の確定済み配置から、氏名・対象者ID・部屋名・利用日程を含む職員限定の配置表を作成します。</p>
    {state?.error && <AlertMessage tone="error" title="配置表PDFを作成できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
    {state?.requested && <AlertMessage tone="success" title="配置表PDFの作成を受け付けました"><p>変換完了後に画面を再読み込みしてください。</p></AlertMessage>}
    {pdf.state === 'pending' && <AlertMessage tone="info" title="配置表PDFを作成中です"><p>しばらくしてから画面を再読み込みしてください。</p></AlertMessage>}
    <div className={styles.actions}>
      {pdf.state === 'ready' && pdf.versionId && <LinkButton href={`/api/staff/camps/room-plan-pdfs/${pdf.versionId}`} variant="primary">最新の配置表PDFを開く</LinkButton>}
      <form action={action}>
        <input type="hidden" name="campId" value={pdf.campId} />
        <input type="hidden" name="rosterVersion" value={pdf.rosterVersion} />
        <input type="hidden" name="rosterLabelVersion" value={pdf.rosterLabelVersion} />
        <input type="hidden" name="roomPlanVersion" value={pdf.roomPlanVersion} />
        <SubmitButton pending={pending} pendingLabel="作成を依頼中…" disabled={pdf.state === 'pending'}>配置表PDFを作成する</SubmitButton>
      </form>
    </div>
  </section>;
}
