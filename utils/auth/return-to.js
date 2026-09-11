/*
 * ログイン後の戻り先（returnTo）を同一オリジンの内部パスだけに絞る。
 *
 * docs/routes.md 8章：
 * 「returnTo は相対パスかつ許可済みの内部ルートだけを受け付ける。完全URL、
 *   プロトコル相対URL、javascript:、外部ドメインは拒否し、オープンリダイレクトを防ぐ」
 *
 * 画面（app/login/page.js）と Server Action（app/actions/auth.js）の両方が
 * 同じ値を検証するため、判定はこのモジュール1か所だけに置く。
 * 片方だけを直すと防御がずれるため、分岐を各所へ複製しない
 * （.claude/rules/security.md）。
 *
 * 判定の考え方：
 * - `/` で始まらない値は外部URL・スキーム付き（`javascript:` など）とみなして拒否する。
 * - `//evil.example` はプロトコル相対URLなので拒否する。
 * - それ以外は URL パーサへ通し、pathname と search だけを組み直す。
 *   これにより `/\evil.example`（バックスラッシュが `//` と同じ扱いになる）や
 *   タブ・改行を混ぜた値も、ホスト部が落ちて内部パスへ正規化される。
 *   hash（`#...`）はサーバーへ送られないため落とす。
 *
 * 依存なしの純粋モジュール（tests/auth-return-to.test.mjs）。
 */

/**
 * 安全な内部パスだけを返す。
 *
 * @param {unknown} value URLクエリやフォームから受け取った戻り先
 * @returns {string|null} 同一オリジンの内部パス。判定できなければ null
 */
export function safeReturnTo(value) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) {
    return null;
  }

  try {
    const url = new URL(value, "http://local");
    return `${url.pathname}${url.search}`;
  } catch {
    return null;
  }
}
