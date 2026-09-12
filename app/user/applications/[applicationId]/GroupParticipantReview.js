import { formatDeadline, formatPeriod } from "@/app/components/format";
import { USAGE_PLACE_LABELS } from "@/app/components/status-labels";
import styles from "./application-view.module.css";

function Item({ label, children, wide = false }) {
  return <div className={wide ? styles.reviewItemWide : styles.reviewItem}>
    <dt>{label}</dt><dd>{children || "未入力"}</dd>
  </div>;
}

export default function GroupParticipantReview({ application }) {
  const fields = application.fields;
  return <div className={styles.reviewSections}>
    <section className={styles.section} aria-labelledby="group-participant-plan-heading">
      <div className={styles.sectionHeading}>
        <h2 className={styles.sectionTitle} id="group-participant-plan-heading">団体の利用内容</h2>
        <p>この内容は団体の代表者が登録しているため、参加者は変更できません。</p>
      </div>
      <dl className={styles.reviewGrid}>
        <Item label="団体名">{application.group_name}</Item>
        <Item label="使用箇所">{USAGE_PLACE_LABELS[application.usage_place] ?? "不明"}</Item>
        <Item label="利用期間" wide>{formatPeriod(application.start_date, application.end_date)}</Item>
        <Item label="使用目的" wide>{application.purpose}</Item>
        <Item label="町内で行う活動" wide>{application.local_activity}</Item>
        {application.active_deadline && <Item label="参加者の提出期限" wide>{formatDeadline(application.active_deadline)}</Item>}
      </dl>
    </section>
    <section className={styles.section} aria-labelledby="group-participant-person-heading">
      <h2 className={styles.sectionTitle} id="group-participant-person-heading">参加者本人の情報</h2>
      <dl className={styles.reviewGrid}>
        <Item label="氏名">{fields.user_name}</Item><Item label="電話番号">{fields.user_phone}</Item>
        <Item label="住所" wide>{fields.user_address}</Item>
      </dl>
    </section>
    <section className={styles.section} aria-labelledby="group-participant-emergency-heading">
      <h2 className={styles.sectionTitle} id="group-participant-emergency-heading">緊急連絡先</h2>
      <dl className={styles.reviewGrid}>
        <Item label="氏名">{fields.emergency_name}</Item><Item label="電話番号">{fields.emergency_phone}</Item>
        <Item label="住所" wide>{fields.emergency_address}</Item>
      </dl>
    </section>
    <section className={styles.section} aria-labelledby="group-participant-note-heading">
      <h2 className={styles.sectionTitle} id="group-participant-note-heading">補足情報</h2>
      <dl className={styles.reviewGrid}>
        <Item label="特記事項" wide>{fields.special_notes || "なし"}</Item>
        <Item label="保護者同意書" wide>{fields.requires_guardian_consent ? (application.has_consent ? "添付済み" : "未添付") : "添付不要"}</Item>
      </dl>
    </section>
  </div>;
}
