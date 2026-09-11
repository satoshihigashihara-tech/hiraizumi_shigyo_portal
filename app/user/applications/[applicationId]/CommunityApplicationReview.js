import { formatMonth, formatPeriod, formatYen } from "@/app/components/format";
import { USAGE_PLACE_LABELS } from "@/app/components/status-labels";
import styles from "./application-view.module.css";

function Item({ label, children, wide = false }) {
  return <div className={wide ? styles.reviewItemWide : styles.reviewItem}>
    <dt>{label}</dt><dd>{children || "未入力"}</dd>
  </div>;
}

export default function CommunityApplicationReview({ application, showEstimatedCharge = true }) {
  const fields = application.fields;
  const months = application.estimated_months ?? [];
  return <div className={styles.reviewSections}>
    <section className={styles.section} aria-labelledby="community-period-heading">
      <h2 className={styles.sectionTitle} id="community-period-heading">利用期間</h2>
      <dl className={styles.reviewGrid}>
        <Item label="利用期間">{fields.start_date && fields.end_date ? formatPeriod(fields.start_date, fields.end_date) : "未設定"}</Item>
        <Item label="使用箇所">{USAGE_PLACE_LABELS[fields.usage_place] ?? "不明"}</Item>
      </dl>
    </section>
    <section className={styles.section} aria-labelledby="community-applicant-heading">
      <h2 className={styles.sectionTitle} id="community-applicant-heading">申請者情報</h2>
      <dl className={styles.reviewGrid}>
        <Item label="氏名">{fields.user_name}</Item><Item label="電話番号">{fields.user_phone}</Item>
        <Item label="住所" wide>{fields.user_address}</Item>
      </dl>
    </section>
    <section className={styles.section} aria-labelledby="community-emergency-heading">
      <h2 className={styles.sectionTitle} id="community-emergency-heading">緊急連絡先</h2>
      <dl className={styles.reviewGrid}>
        <Item label="氏名">{fields.emergency_name}</Item><Item label="電話番号">{fields.emergency_phone}</Item>
        <Item label="住所" wide>{fields.emergency_address}</Item>
      </dl>
    </section>
    <section className={styles.section} aria-labelledby="community-use-heading">
      <h2 className={styles.sectionTitle} id="community-use-heading">利用内容</h2>
      <dl className={styles.reviewGrid}>
        <Item label="使用目的" wide>{fields.purpose}</Item>
        <Item label="町内で行う活動" wide>{fields.local_activity}</Item>
        <Item label="特記事項" wide>{fields.special_notes || "なし"}</Item>
        <Item label="保護者同意書" wide>{fields.requires_guardian_consent ? (application.has_consent ? "添付済み" : "未添付") : "添付不要"}</Item>
      </dl>
    </section>
    {showEstimatedCharge && <section className={styles.section} aria-labelledby="community-charge-heading">
      <div className={styles.sectionHeading}>
        <h2 className={styles.sectionTitle} id="community-charge-heading">料金見込み</h2>
        <p>1人1日300円、暦月ごとに上限9,000円です。</p>
      </div>
      <div className={styles.chargeSummary}><span>合計見込み</span><strong>{formatYen(months.reduce((sum, row) => sum + (row.amount ?? 0), 0))}</strong></div>
      <dl className={styles.chargeBreakdown}>{months.map((row) => <div key={row.month}>
        <dt>{formatMonth(row.month)}</dt><dd>{row.usage_days}日 × {formatYen(row.daily_rate)}<strong>{formatYen(row.amount)}</strong></dd>
      </div>)}</dl>
      <p className={styles.chargeNote}>表示額は見込みです。提出時にサーバーで再計算します。</p>
    </section>}
  </div>;
}
