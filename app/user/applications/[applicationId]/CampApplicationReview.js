import { formatMonth, formatPeriod, formatYen } from "@/app/components/format";
import {
  ROOM_PREFERENCE_LABELS,
  USAGE_PLACE_LABELS,
} from "@/app/components/status-labels";
import styles from "./application-view.module.css";

function ReviewItem({ label, children, wide = false }) {
  return (
    <div className={wide ? styles.reviewItemWide : styles.reviewItem}>
      <dt>{label}</dt>
      <dd>{children || "未入力"}</dd>
    </div>
  );
}

export default function CampApplicationReview({
  application,
  showEstimatedCharge = true,
}) {
  const { fields, estimatedCharge } = application;

  return (
    <div className={styles.reviewSections}>
      <section className={styles.section} aria-labelledby="period-heading">
        <h2 className={styles.sectionTitle} id="period-heading">
          キャンプと利用期間
        </h2>
        <dl className={styles.reviewGrid}>
          <ReviewItem label="キャンプ名">{application.campName}</ReviewItem>
          <ReviewItem label="利用期間">
            {formatPeriod(application.startDate, application.endDate)}
          </ReviewItem>
        </dl>
      </section>

      <section className={styles.section} aria-labelledby="applicant-heading">
        <h2 className={styles.sectionTitle} id="applicant-heading">
          申請者情報
        </h2>
        <dl className={styles.reviewGrid}>
          <ReviewItem label="氏名">{fields.applicantName}</ReviewItem>
          <ReviewItem label="電話番号">{fields.applicantPhone}</ReviewItem>
          <ReviewItem label="住所" wide>
            {fields.applicantAddress}
          </ReviewItem>
        </dl>
      </section>

      <section className={styles.section} aria-labelledby="emergency-heading">
        <h2 className={styles.sectionTitle} id="emergency-heading">
          緊急連絡先
        </h2>
        <dl className={styles.reviewGrid}>
          <ReviewItem label="氏名">{fields.emergencyContactName}</ReviewItem>
          <ReviewItem label="電話番号">
            {fields.emergencyContactPhone}
          </ReviewItem>
          <ReviewItem label="住所" wide>
            {fields.emergencyContactAddress}
          </ReviewItem>
        </dl>
      </section>

      <section className={styles.section} aria-labelledby="use-heading">
        <h2 className={styles.sectionTitle} id="use-heading">
          利用内容
        </h2>
        <dl className={styles.reviewGrid}>
          <ReviewItem label="使用箇所">
            {USAGE_PLACE_LABELS[fields.usagePlace] ?? "不明"}
          </ReviewItem>
          <ReviewItem label="部屋の希望">
            {ROOM_PREFERENCE_LABELS[fields.requestedRoomPreference] ?? "不明"}
          </ReviewItem>
          <ReviewItem label="使用目的" wide>
            {fields.usagePurpose}
          </ReviewItem>
          <ReviewItem label="特記事項" wide>
            {fields.notes || "なし"}
          </ReviewItem>
          <ReviewItem label="保護者同意書" wide>
            {fields.guardianConsentRequired === "true"
              ? application.consent
                ? "添付済み"
                : "未添付"
              : "添付不要"}
          </ReviewItem>
        </dl>
      </section>

      {showEstimatedCharge && (
      <section className={styles.section} aria-labelledby="charge-heading">
        <div className={styles.sectionHeading}>
          <h2 className={styles.sectionTitle} id="charge-heading">
            料金見込み
          </h2>
          <p>1人1日300円、暦月ごとに上限9,000円です。</p>
        </div>
        <div className={styles.chargeSummary}>
          <span>合計見込み</span>
          <strong>{formatYen(estimatedCharge.totalAmount)}</strong>
        </div>
        <dl className={styles.chargeBreakdown}>
          {estimatedCharge.months.map((row) => (
            <div key={row.month}>
              <dt>{formatMonth(row.month)}</dt>
              <dd>
                {row.usageDays}日 × {formatYen(row.dailyRate)}
                <strong>{formatYen(row.amount)}</strong>
              </dd>
            </div>
          ))}
        </dl>
        <p className={styles.chargeNote}>
          表示額は現在の申請内容による見込みです。提出時にサーバーで再計算されます。
        </p>
      </section>
      )}
    </div>
  );
}
