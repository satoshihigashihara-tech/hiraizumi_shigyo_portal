import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import SubmitButton from "@/app/components/SubmitButton";
import { formatDeadline, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { createCampApplicationDraft } from "@/app/actions/camp-applications";
import { getEligibleCamps } from "@/utils/camp-applications/queries";
import styles from "./page.module.css";

export const metadata = {
  title: "キャンプを選ぶ｜ひらいずみ志業ポータル",
  description: "申請対象のスパルタキャンプと固定の利用期間を確認します。",
};

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

function isDeadlinePassed(deadline, now) {
  return Date.parse(deadline) <= now.getTime();
}

function CampCard({ camp, now }) {
  const deadlinePassed = isDeadlinePassed(camp.application_deadline, now);

  return (
    <li className={styles.card}>
      <div className={styles.cardHeader}>
        <h2 className={styles.cardTitle}>{camp.name}</h2>
        <p className={styles.fixedPeriod}>利用期間は固定です</p>
      </div>

      <dl className={styles.facts}>
        <div className={styles.fact}>
          <dt>利用期間</dt>
          <dd>{formatPeriod(camp.start_date, camp.end_date)}</dd>
        </div>
        <div className={styles.fact}>
          <dt>申請期限</dt>
          <dd>{formatDeadline(camp.application_deadline)}</dd>
        </div>
      </dl>

      <p className={styles.periodNote}>
        キャンプの利用期間は職員が設定しています。利用者による日程の変更はできません。
      </p>

      {deadlinePassed ? (
        <AlertMessage tone="warning" title="受付期間が終了しました">
          <p>受付期間が終了しました。町へ直接お問い合わせください。</p>
        </AlertMessage>
      ) : (
        <form className={styles.form} action={createCampApplicationDraft}>
          <input type="hidden" name="campId" value={camp.id} />
          <SubmitButton pendingLabel="下書きを作成中…" fullWidthOnMobile>
            このキャンプで申請を始める
          </SubmitButton>
          <p className={styles.formNote}>
            ボタンを押すと下書きを作成し、申請内容の入力画面へ進みます。
          </p>
        </form>
      )}
    </li>
  );
}

export default async function CampSelectionPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const errorCode = firstQueryValue(query.error);
  const { error, camps } = await getEligibleCamps();
  const now = new Date();

  return (
    <PageShell
      audienceMode="camp"
      title="キャンプを選ぶ"
      description="申請するキャンプ、固定の利用期間、申請期限を確認してください。"
    >
      {errorCode && (
        <AlertMessage tone="error" title="下書きを作成できませんでした">
          <p>{errorMessage(errorCode)}</p>
        </AlertMessage>
      )}

      {error ? (
        <AlertMessage tone="error" title="キャンプを読み込めませんでした">
          <p>{errorMessage(error)}</p>
        </AlertMessage>
      ) : camps.length === 0 ? (
        <EmptyState
          title="申請できるキャンプはありません"
          description="対象のキャンプが登録されると、この画面に表示されます。登録状況については町へお問い合わせください。"
        />
      ) : (
        <section className={styles.section} aria-labelledby="eligible-camps-heading">
          <h2 className={styles.sectionTitle} id="eligible-camps-heading">
            対象のキャンプ
          </h2>
          <p className={styles.sectionNote}>
            あなたの登録メールアドレスが対象者として登録されているキャンプだけを表示しています。
          </p>
          <ul className={styles.cardList} role="list">
            {camps.map((camp) => (
              <CampCard key={camp.id} camp={camp} now={now} />
            ))}
          </ul>
        </section>
      )}

      <div className={styles.backLink}>
        <LinkButton href="/user/applications/new" fullWidthOnMobile>
          申請方法の選択へ戻る
        </LinkButton>
      </div>
    </PageShell>
  );
}
