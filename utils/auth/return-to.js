/*
 * ログイン後の戻り先（returnTo）を同一オリジンの内部パスだけに絞る。
 *
 * docs/routes.md 8章：
 * 「returnTo は相対パスかつ許可済みの内部ルートだけを受け付ける。完全URL、
 *   プロトコル相対URL、javascript:、外部ドメインは拒否し、オープンリダイレクトを防ぐ」
 *
 * 画面（app/login/page.js）・Server Action（app/actions/auth.js）・
 * ルートガード（utils/auth/guards.js）のすべてが同じ値を検証するため、
 * 判定はこのモジュール1か所だけに置く。片方だけを直すと防御がずれるため、
 * 分岐を各所へ複製しない（.claude/rules/security.md）。
 *
 * 判定の考え方：
 * - 前後の空白は落としてから判定する。呼び出し元が生のクエリ値を渡すか
 *   trim 済みの値を渡すかで結果が変わらないようにするため。
 * - `/` で始まらない値は外部URL・スキーム付き（`javascript:` など）とみなして拒否する。
 * - `//evil.example` はプロトコル相対URLなので拒否する。
 * - それ以外は URL パーサへ通し、pathname と search だけを組み直す。
 *   これにより `/\evil.example`（バックスラッシュが `//` と同じ扱いになる）や
 *   タブ・改行を混ぜた値も、ホスト部が落ちて内部パスへ正規化される。
 *   hash（`#...`）はサーバーへ送られないため落とす。
 * - 正規化した結果も `//` で始まらないことを最後に確かめる。入口の検査だけでは
 *   すり抜ける値があるため（下記）。
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
  if (typeof value !== "string") {
    return null;
  }

  // 呼び出し元によって trim 済み・生のクエリ値が混ざるため、ここで揃える。
  const trimmed = value.trim();

  if (!trimmed.startsWith("/") || trimmed.startsWith("//")) {
    return null;
  }

  try {
    const url = new URL(trimmed, "http://local");
    const path = `${url.pathname}${url.search}`;

    // 正規化後も `//` で始まることがある。`/..` は根で打ち消されるため
    // `/..//evil.example` は入口の検査（`//` 始まり）を通過したうえで
    // pathname が `//evil.example` になる。そのまま redirect すると
    // プロトコル相対URLとして外部へ出るので、出口でもう一度弾く。
    return path.startsWith("//") ? null : path;
  } catch {
    return null;
  }
}
