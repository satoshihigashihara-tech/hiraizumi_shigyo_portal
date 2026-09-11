import { signUp } from "@/app/actions/auth";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { safeReturnTo } from "@/utils/auth/return-to";
import styles from "./page.module.css";

const FIELD_ERRORS = {
  short: { password: "short" },
};

function firstParam(value) {
  if (Array.isArray(value)) return typeof value[0] === "string" ? value[0] : "";
  return typeof value === "string" ? value : "";
}

async function readQuery(searchParams) {
  const query = (await searchParams) ?? {};
  return {
    errorCode: firstParam(query.error),
    noticeCode: firstParam(query.notice),
    returnTo: safeReturnTo(firstParam(query.returnTo)),
  };
}

export async function generateMetadata({ searchParams }) {
  const { errorCode, noticeCode } = await readQuery(searchParams);
  const prefix = errorCode
    ? "登録できませんでした"
    : noticeCode === "confirm"
      ? "確認メールを送信しました"
      : "新規登録";

  return {
    title: `${prefix}｜ひらいずみ志業ポータル`,
    description: "ひらいずみ志業ポータルの利用者アカウントを作成します。",
  };
}

export default async function SignUpPage({ searchParams }) {
  const { errorCode, noticeCode, returnTo } = await readQuery(searchParams);
  const fieldErrors = Object.hasOwn(FIELD_ERRORS, errorCode)
    ? FIELD_ERRORS[errorCode]
    : null;
  const loginHref = returnTo
    ? `/login?returnTo=${encodeURIComponent(returnTo)}`
    : "/login";

  return (
    <div className={styles.page}>
      <PageShell
        title="新規登録"
        description="申請に使用するメールアドレスとパスワードを登録してください。"
      >
        {errorCode && (
          <AlertMessage tone="error" title="登録できませんでした">
            <p>{errorMessage(errorCode)}</p>
          </AlertMessage>
        )}

        {noticeCode === "confirm" && (
          <AlertMessage tone="success" title="確認メールを送信しました">
            <p>{errorMessage("confirm")}</p>
          </AlertMessage>
        )}

        {noticeCode !== "confirm" && (
          <form className={styles.form} action={signUp}>
            {returnTo && <input type="hidden" name="returnTo" value={returnTo} />}

            <FormField
              id="email"
              name="email"
              label="メールアドレス"
              type="email"
              inputMode="email"
              autoComplete="username"
              placeholder="example@example.com"
              required
            />

            <FormField
              id="password"
              name="password"
              label="パスワード"
              type="password"
              autoComplete="new-password"
              hint="6文字以上で入力してください。"
              required
              error={fieldErrors?.password}
            />

            <div className={styles.actions}>
              <SubmitButton pendingLabel="登録中…" fullWidthOnMobile>
                アカウントを作成
              </SubmitButton>
            </div>
          </form>
        )}

        <div className={styles.footer}>
          <p>すでにアカウントをお持ちの方</p>
          <LinkButton href={loginHref} fullWidthOnMobile>
            ログイン
          </LinkButton>
          <LinkButton href="/" fullWidthOnMobile>
            トップへ戻る
          </LinkButton>
        </div>
      </PageShell>
    </div>
  );
}
