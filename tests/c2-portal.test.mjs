import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("public landing links to the two-choice screen moved to /welcome-user", async () => {
  const [top, welcome, camp, styles] = await Promise.all([
    read("app/page.js"), read("app/welcome-user/page.js"), read("app/camp/page.js"), read("app/welcome-user/page.module.css"),
  ]);
  assert.match(top, />申請を始める<\/Link>/);
  assert.match(top, /href="\/welcome-user"/);
  assert.match(top, /<h2 id="service-name">ひらいずみ志業ポータル<\/h2>/);
  assert.match(top, /平泉町志業シェアハウスの利用申請から審査/);
  assert.doesNotMatch(top, /参加のかたちに合う入口から|空き状況は、ログイン前に|application-choices|availability-calendar/);
  assert.match(welcome, /スパルタキャンプに参加する方/);
  assert.match(welcome, /大学・学生団体でフィールドワークを行う方/);
  assert.match(welcome, /href="\/camp"/);
  assert.match(welcome, /href="\/user\?mode=fieldwork"/);
  assert.match(styles, /grid-template-columns: repeat\(2/);
  assert.match(styles, /@media \(max-width: 767px\).*grid-template-columns: 1fr/s);
  assert.match(camp, /audienceMode="camp"/);
  assert.match(camp, /1人につき1日300円/);
});

test("common chrome is shared and every screen gets the exact project copyright", async () => {
  const [layout, header, footer, globalStyles] = await Promise.all([
    read("app/layout.js"), read("app/components/SiteHeader.js"),
    read("app/components/SiteFooter.js"), read("app/globals.css"),
  ]);
  assert.match(layout, /<SiteHeader/);
  assert.match(layout, /<SiteFooter/);
  assert.doesNotMatch(layout, /getSessionUser|getActiveViewer|staff_roles|profiles/);
  assert.match(header, /共通メニュー/);
  assert.match(header, /className=\{styles\.brand\} href="\/"/);
  assert.match(header, /pathname === "\/"\) return null/);
  assert.doesNotMatch(layout, />利用する方へ</);
  assert.match(header, /\["\/welcome-user", "申請を始める"\]/);
  assert.doesNotMatch(header, /\["\/camp", "キャンプ利用"\]/);
  assert.match(footer, /© 2026 ひらいずみ志業ポータル開発チーム/);
  assert.doesNotMatch(footer, /© 2026 平泉町/);
  assert.match(globalStyles, /color-scheme: light/);
  assert.doesNotMatch(globalStyles, /prefers-color-scheme:\s*dark/);
});

test("user-facing return buttons lead back to the usage selection screen", async () => {
  const sources = await Promise.all([
    "app/user/profile/page.js",
    "app/user/applications/page.js",
    "app/user/applications/[applicationId]/complete/page.js",
    "app/invite/[token]/page.js",
  ].map(read));

  for (const source of sources) {
    assert.doesNotMatch(source, /<LinkButton href="\/user"/);
    assert.match(source, /href="\/welcome-user"/);
  }
});

test("camp and fieldwork use the simplified home navigation", async () => {
  const [camp, login, home, applications, groups, chooser] = await Promise.all([
    read("app/camp/page.js"),
    read("app/login/page.js"),
    read("app/user/page.js"),
    read("app/user/applications/page.js"),
    read("app/user/groups/page.js"),
    read("app/user/applications/new/page.js"),
  ]);
  assert.doesNotMatch(camp, /はじめての方はこちら|\/signup/);
  assert.doesNotMatch(login, /初めて利用する方|>\s*新規登録\s*</);
  assert.doesNotMatch(login, /href=\{?[^\n]*\/signup/);
  assert.match(applications, /mode === "camp"\) redirect\("\/user\?mode=camp"\)/);
  assert.match(groups, /redirect\(withMode\("\/user", mode\)\)/);
  assert.match(chooser, /mode === "fieldwork"\) redirect\("\/user\/groups\/new\?mode=fieldwork"\)/);
  assert.match(home, /pageTitle = isFieldwork \? "団体利用者ホーム"/);
  assert.match(home, /href="\/user\/groups\/new\?mode=fieldwork"/);
  assert.doesNotMatch(home, /その他の操作|aria-labelledby="links-heading"/);
});

test("mode helpers accept only camp and fieldwork and preserve query strings", async () => {
  const source = await read("utils/navigation/mode.js");
  const context = vm.createContext({});
  const loadedModule = new vm.SourceTextModule(source, { context });
  await loadedModule.link(() => { throw new Error("mode helper must stay dependency-free"); });
  await loadedModule.evaluate();
  const { normalizeMode, withMode, usageTypeForMode } = loadedModule.namespace;
  assert.equal(normalizeMode("camp"), "camp");
  assert.equal(normalizeMode("fieldwork"), "fieldwork");
  assert.equal(normalizeMode("staff"), null);
  assert.equal(withMode("/user/applications?start=2026-10-01", "camp"), "/user/applications?start=2026-10-01&mode=camp");
  assert.equal(usageTypeForMode("fieldwork"), "community_group");
});

test("proxy stays DB-free while DAL caches auth and parallelizes independent access reads", async () => {
  const [proxy, middleware, session, applications] = await Promise.all([
    read("proxy.js"), read("utils/supabase/middleware.js"),
    read("utils/auth/session.js"), read("utils/user-applications/queries.js"),
  ]);
  assert.doesNotMatch(`${proxy}\n${middleware}`, /\.from\(|staff_roles|profiles/);
  assert.match(middleware, /auth\.getClaims\(\)/);
  assert.match(session, /cache\(async/);
  assert.match(session, /Promise\.all\(\[profileRequest, staffRequest\]\)/);
  const filter = applications.indexOf('request = request.eq("usage_type", usageType)');
  const order = applications.indexOf('.order("created_at"');
  const limit = applications.indexOf(".limit(100)");
  assert.ok(filter > -1 && filter < order && order < limit);
});
