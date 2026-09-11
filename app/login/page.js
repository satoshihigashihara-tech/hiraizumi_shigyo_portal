import { login } from "@/app/actions/auth";
import AlertMessage from "@/app/components/AlertMessage";
import ComingSoon from "@/app/components/ComingSoon";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "./page.module.css";

/*
 * ログイン画面（/login）。Server Component（docs/routes.md 5章・9.1）。
 *
 * 画面・入力欄・エラー表示だけを担当し、認証処理そのものは
 * app/actions/auth.js の login（Server Action）に委ねる
 * （docs/frontend-handoff.md の担当表）。
 *
 * フォームの name は docs/tasks.md 4.1 の契約に合わせる：
 *   email / password / 任意の returnTo
 *
 * 失敗時、login Action は `/login?error=コード&returnTo=...` へ redirect する
 * （app/actions/auth.js の loginErrorUrl）。この画面はそのコードを
 * messages.js の errorMessage() で日本語へ変換して表示し、コード文字列を
 * 画面へ出さない（docs/coding_rules.md 4章）。
 */

export const metadata = {
  title: "ログイン｜ひらいずみ志業ポータル",
  description: "ひらいずみ志業ポータルへログインします。",
};

/*
 * エラーコード → 項目別エラー（入力欄の下に出す分）。
 *
 * login Action は「どの項目が原因か」を返さないため、コードだけで
 * 項目を特定できるものに限って対応付ける。`required`（未入力）と
 * `invalid`（メールまたはパスワードが違う）は、どちらの欄が原因か
 * 判別できないので上部の案内だけにし、正しく入力された欄へ
 * aria-invalid を付けない。
 *
 * 将来 login Action が fieldErrors を返すようになったら、
 * AlertMessage の errorAlertItems(fieldErrors) を items へ渡すと
 * 「エラー箇所へ移動する」リンクも出せる（docs/requirements.md 8.3）。
 */
const FIELD_ERRORS_BY_CODE = {
  // 「6文字以上」はパスワードだけの条件（app/actions/auth.js の signUp）
  short: { password: "short" },
};

/**
 * URLクエリの値を1つの文字列にする。
 * `?error=a&error=b` のように配列で来ることがあるため先頭だけを使う。
 *
 * @param {string|string[]|undefined} value
 * @returns {string}
 */
function firstParam(value) {
  if (Array.isArray(value)) {
    return typeof value[0] === "string" ? value[0] : "";
  }
  return typeof value === "string" ? value : "";
}

/**
 * returnTo を同一オリジンの内部パスだけに絞る。
 *
 * app/actions/auth.js の getSafeReturnTo と同じ規則。Action 側でも必ず
 * 検証されるが、画面側でも絞ることで `//evil.example` のような値を
 * hidden input へ書き戻さない（.claude/rules/security.md）。
 *
 * @param {string} value
 * @returns {string|null} 安全な内部パス。判定できなければ null
 */
function safeReturnTo(value) {
  if (!value || !value.startsWith("/") || value.startsWith("//")) {
    return null;
  }

  try {
    const url = new URL(value, "http://local");
    return `${url.pathname}${url.search}`;
  } catch {
    return null;
  }
}

export default async function LoginPage({ searchParams }) {
  // Next.js 16 では searchParams は Promise
  // （node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/page.md）
  const query = (await searchParams) ?? {};
  const errorCode = firstParam(query.error);
  const returnTo = safeReturnTo(firstParam(query.returnTo));

  // Object.hasOwn で自前のキーに限定する（messages.js と同じ対策）。
  // `FIELD_ERRORS_BY_CODE[code]` だけでは "toString" などが関数として返る。
  const fieldErrors =
    errorCode && Object.hasOwn(FIELD_ERRORS_BY_CODE, errorCode)
      ? FIELD_ERRORS_BY_CODE[errorCode]
      : null;

  return (
    <div className={styles.page}>
      <PageShell
        title="ログイン"
        description="登録済みのメールアドレスとパスワードを入力してください。"
      >
        {errorCode && (
          <AlertMessage tone="error" title="ログインできませんでした">
            <p>{errorMessage(errorCode)}</p>
          </AlertMessage>
        )}

        {returnTo && (
          <AlertMessage tone="info" title="ログインが必要な画面です">
            <p>ログインすると、直前に開いていた画面へ戻ります。</p>
          </AlertMessage>
        )}

        <form className={styles.form} action={login}>
          {/* 安全と判定できた内部パスだけを Action へ渡す */}
          {returnTo && <input type="hidden" name="returnTo" value={returnTo} />}

          {/* id は name と同じにする（app/components/README.md） */}
          <FormField
            id="email"
            name="email"
            label="メールアドレス"
            type="email"
            inputMode="email"
            autoComplete="email"
            placeholder="example@example.com"
            required
            error={fieldErrors?.email}
          />

          <FormField
            id="password"
            name="password"
            label="パスワード"
            type="password"
            autoComplete="current-password"
            required
            error={fieldErrors?.password}
          />

          {/* useFormStatus の制約上、SubmitButton は必ず form の内側へ置く */}
          <div className={styles.actions}>
            <SubmitButton pendingLabel="ログイン中…" fullWidthOnMobile>
              ログイン
            </SubmitButton>
          </div>
        </form>

        {/*
         * 新規登録（/signup）とパスワード再設定（/forgot-password）は
         * この段階の対象外。動くように見えるボタンを置かず、
         * ComingSoon（<a>も<button>も描画しない部品）で案内する
         * （docs/frontend-handoff.md・イシュー #17 の注意事項）。
         */}
        <ComingSoon
          title="新規登録・パスワードの再設定"
          description="現在は準備中です。ログインできないときは、町の担当へお問い合わせください。"
        />

        <div className={styles.footer}>
          <LinkButton href="/" fullWidthOnMobile>
            トップへ戻る
          </LinkButton>
        </div>
      </PageShell>
    </div>
  );
}
