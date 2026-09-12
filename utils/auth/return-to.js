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
 * - 制御文字とバックスラッシュは、URL パーサへ渡す前に拒否する。
 * - `/` で始まらない値は外部URL・スキーム付き（`javascript:` など）とみなして拒否する。
 * - `//evil.example` はプロトコル相対URLなので拒否する。
 * - それ以外は URL パーサへ通し、許可した pathname と search だけを返す。
 *   hash はサーバー側の遷移先契約に含めないため拒否する。
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

  if (/[\\\u0000-\u001f\u007f]/.test(value)) return null;
  const trimmed = value.trim();

  if (!trimmed.startsWith("/") || trimmed.startsWith("//")) {
    return null;
  }
  const rawPath = trimmed.split(/[?#]/, 1)[0];
  if (/(?:^|\/)(?:\.|%2e){1,2}(?:\/|$)/i.test(rawPath)) return null;

  try {
    const url = new URL(trimmed, "http://local");
    if (url.origin !== "http://local" || url.hash || !allowedPath(url.pathname)) return null;
    const seen = new Set();
    const allowed = allowedQueries(url.pathname);
    for (const [key] of url.searchParams) {
      if (seen.has(key) || !allowed.has(key)) return null;
      seen.add(key);
    }
    if (url.searchParams.has("mode") && !["camp", "fieldwork"].includes(url.searchParams.get("mode"))) return null;
    if (url.searchParams.has("page") && !/^[1-9]\d{0,3}$/.test(url.searchParams.get("page"))) return null;
    if (url.searchParams.has("month") && !/^\d{4}-(0[1-9]|1[0-2])$/.test(url.searchParams.get("month"))) return null;
    for (const key of ["start", "end", "date"]) {
      if (url.searchParams.has(key) && !/^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get(key))) return null;
    }
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

const UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}";
const PATHS = [
  /^\/user(?:\/profile)?$/,
  /^\/user\/applications(?:\/new(?:\/camp|\/community-activity)?)?$/,
  new RegExp(`^/user/applications/${UUID}(?:/(?:edit|confirm|complete|cancel|extension))?$`),
  /^\/user\/groups(?:\/new)?$/,
  new RegExp(`^/user/groups/${UUID}(?:/(?:edit|confirm|complete|participants))?$`),
  /^\/invite$/,
  /^\/invite\/[A-Za-z0-9_-]{6,256}$/,
  /^\/staff$/,
  /^\/staff\/camps(?:\/new)?$/,
  new RegExp(`^/staff/camps/${UUID}(?:/(?:edit|eligible-users))?$`),
  new RegExp(`^/staff/camps/${UUID}/applications/${UUID}$`),
  /^\/staff\/community\/groups$/,
  new RegExp(`^/staff/community/groups/${UUID}$`),
  new RegExp(`^/staff/community/applications/${UUID}$`),
  /^\/staff\/calendar(?:\/blocked-periods(?:\/new)?)?$/,
  new RegExp(`^/staff/calendar/blocked-periods/${UUID}/edit$`),
];

function allowedPath(pathname) {
  return PATHS.some((pattern) => pattern.test(pathname));
}

function allowedQueries(pathname) {
  if (pathname === "/staff") return new Set(["q", "usageType", "status", "page"]);
  if (pathname === "/staff/community/groups") return new Set(["q", "status", "page"]);
  if (pathname.startsWith("/staff/calendar")) return new Set(["month", "date"]);
  if (pathname === "/user/groups") return new Set(["mode", "page"]);
  if (pathname.startsWith("/user/")) return new Set(["mode", "start", "end"]);
  if (pathname === "/invite" || pathname.startsWith("/invite/")) return new Set(["mode"]);
  return new Set();
}
