import { formatPeriod } from "@/app/components/format";
import { USAGE_PLACE_LABELS } from "@/app/components/status-labels";
import styles from "./groups.module.css";

function Fact({ label, children }) {
  return <div><dt>{label}</dt><dd>{children || "未設定"}</dd></div>;
}

export default function GroupReview({ group }) {
  const fields = group.fields;
  return (
    <>
      <section className={styles.panel} aria-labelledby="group-information-heading">
        <h2 id="group-information-heading">団体情報</h2>
        <dl className={styles.facts}>
          <Fact label="団体名">{fields.group_name}</Fact>
          <Fact label="代表者氏名">{fields.representative_name}</Fact>
          <Fact label="代表者住所">{fields.representative_address}</Fact>
          <Fact label="代表者電話番号">{fields.representative_phone}</Fact>
          <Fact label="利用期間">{formatPeriod(fields.start_date, fields.end_date)}</Fact>
          <Fact label="予定人数">{fields.planned_participants ? `${fields.planned_participants}人` : null}</Fact>
          <Fact label="代表者の宿泊">{fields.representative_stays === true ? "宿泊する" : "宿泊しない"}</Fact>
        </dl>
      </section>
      <section className={styles.panel} aria-labelledby="group-activity-heading">
        <h2 id="group-activity-heading">利用内容</h2>
        <dl className={styles.facts}>
          <Fact label="使用箇所">{Object.hasOwn(USAGE_PLACE_LABELS, fields.usage_place) ? USAGE_PLACE_LABELS[fields.usage_place] : "不明"}</Fact>
          <Fact label="使用目的">{fields.purpose}</Fact>
          <Fact label="町内で行う活動">{fields.local_activity}</Fact>
          <Fact label="特記事項">{fields.special_notes || "なし"}</Fact>
        </dl>
      </section>
    </>
  );
}
