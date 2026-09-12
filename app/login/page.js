import { login } from "@/app/actions/auth";
import { redirect } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { safeReturnTo } from "@/utils/auth/return-to";
import { destinationForViewer } from "@/utils/auth/destination";
import { getActiveViewer } from "@/utils/auth/session";
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
 *
 * 未確定事項：ログイン済みの利用者が /login を直接開いたときの扱いは
 * docs/routes.md 8章に規定がなく、現状はフォームをそのまま表示する。
 * 本接続時に「/user・/staff へ送る」か「そのまま表示する」かを決める。
 */

/**
 * エラーコード → 画面上部の見出し。
 *
 * 既定は「ログインできませんでした」だが、`login-required`（有効期限切れ。
 * app/actions/camp-applications.js・guardian-consent.js が返す）は
 * ログインを試した結果ではないため、本文と噛み合う見出しへ差し替える。
 */
const ERROR_TITLES_BY_CODE = {
  "login-required": "もう一度ログインしてください",
};

const DEFAULT_ERROR_TITLE = "ログインできませんでした";

/**
 * エラーコードに対応する見出しを返す。
 *
 * Object.hasOwn で自前のキーに限定する（messages.js と同じ対策）。
 * `ERROR_TITLES_BY_CODE[code]` だけでは "toString" などが関数として返る。
 *
 * @param {string} code
 * @returns {string}
 */
function errorTitle(code) {
  return Object.hasOwn(ERROR_TITLES_BY_CODE, code)
    ? ERROR_TITLES_BY_CODE[code]
    : DEFAULT_ERROR_TITLE;
}

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
  // 「6文字以上」はパスワードだけの条件（app/actions/auth.js の signUp）。
  // login Action は required / invalid しか返さないため、このコードは
  // /login のフォーム送信では発生しない。`/login?error=short` を直接開いた
  // ときの表示崩れを防ぐために残しており、/signup を実装する際は
  // その画面へ移すか、両画面で共有する辞書へ切り出す（イシュー #17 の後続）。
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
 * URLクエリの読み取りを1か所へまとめる。
 *
 * generateMetadata と LoginPage の双方が同じ値を必要とするため、
 * 展開と変換をここへ集約する。エラーコードの読み取り方を変えるときに
 * 2か所を直さなくて済むようにするのが目的。
 *
 * @param {Promise<Record<string, string|string[]|undefined>>|undefined} searchParams
 * @returns {Promise<{errorCode: string, returnTo: string|null}>}
 */
async function readQuery(searchParams) {
  // Next.js 16 では searchParams は Promise
  // （node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/page.md）
  const query = (await searchParams) ?? {};

  return {
    errorCode: firstParam(query.error),
    // Action 側（app/actions/auth.js）でも必ず検証されるが、画面側でも絞ることで
    // `//evil.example` のような値を hidden input へ書き戻さない。判定規則は
    // utils/auth/return-to.js に一本化している（.claude/rules/security.md）。
    returnTo: safeReturnTo(firstParam(query.returnTo)),
  };
}

/*
 * ページタイトルにもエラーを反映する。
 *
 * エラーはリダイレクト後のページ全体読み込みで描画されるため、
 * AlertMessage のライブリージョン（role="alert"）は「読み込み後の変化」が
 * 起きず読み上げられないことが多い。スクリーンリーダーは新しいページの
 * タイトルを読むため、失敗した事実をタイトル側でも伝える
 * （docs/coding_rules.md 7章）。
 */
export async function generateMetadata({ searchParams }) {
  const { errorCode } = await readQuery(searchParams);

  return {
    title: errorCode
      ? `${errorTitle(errorCode)}｜ログイン｜ひらいずみ志業ポータル`
      : "ログイン｜ひらいずみ志業ポータル",
    description: "ひらいずみ志業ポータルへログインします。",
  };
}

export default async function LoginPage({ searchParams }) {
  const { errorCode, returnTo } = await readQuery(searchParams);
  const viewer = await getActiveViewer();
  if (viewer.user) redirect(destinationForViewer(returnTo, viewer));

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
          <AlertMessage tone="error" title={errorTitle(errorCode)}>
            <p>{errorMessage(errorCode)}</p>
          </AlertMessage>
        )}

        {returnTo && (
          <AlertMessage tone="info" title="ログインが必要な画面です">
            {/*
             * 「直前の画面へ戻る」とは言い切らない。app/actions/auth.js の
             * destinationForRole は、職員が /user/... を、一般利用者が
             * /staff/... を returnTo に持つとき別の画面へ送るため。
             */}
            <p>ログインすると、権限に応じた画面へ移動します。</p>
          </AlertMessage>
        )}

        <form className={styles.form} action={login}>
          {/* 安全と判定できた内部パスだけを Action へ渡す */}
          {returnTo && <input type="hidden" name="returnTo" value={returnTo} />}

          {/*
           * id は name と同じにする（app/components/README.md）。
           *
           * 未対応：認証失敗後に入力済みのメールアドレスが消える
           * （docs/requirements.md 8.3「入力済みの内容を保持する」）。
           * 現在の login Action は redirect するだけで入力値を返さないため、
           * 画面側だけでは解決できない。本接続で Action を useActionState 対応
           * （`{ error, fields, fieldErrors }` を返す形）へ変更したら、
           * ここへ defaultValue={state?.fields?.email} を渡す。FormField は
           * 非制御入力なので defaultValue を足すだけで保持が成立する。
           * パスワードは保持しない（現状の挙動のままでよい）。
           *
           * autoComplete は current-password と対になる username を使う。
           * email でも動作するが、パスワードマネージャの認識率が上がる。
           */}
          <FormField
            id="email"
            name="email"
            label="メールアドレス"
            type="email"
            inputMode="email"
            autoComplete="username"
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

        <section className={styles.accountHelp} aria-labelledby="account-help-title">
          <h2 id="account-help-title">初めて利用する方</h2>
          <p>利用者アカウントを作成してから申請へ進んでください。</p>
          <LinkButton
            href={returnTo ? `/signup?returnTo=${encodeURIComponent(returnTo)}` : "/signup"}
            fullWidthOnMobile
          >
            新規登録
          </LinkButton>
        </section>

        <div className={styles.footer}>
          <LinkButton href="/" fullWidthOnMobile>
            トップへ戻る
          </LinkButton>
        </div>
      </PageShell>
    </div>
  );
}
