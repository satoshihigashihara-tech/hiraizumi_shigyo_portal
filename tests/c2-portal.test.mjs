import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("public top is the two-choice landing page and camp content moved to /camp", async () => {
  const [top, camp, styles] = await Promise.all([
    read("app/page.js"), read("app/camp/page.js"), read("app/page.module.css"),
  ]);
  assert.match(top, /スパルタキャンプに参加する方/);
  assert.match(top, /大学・学生団体でフィールドワークを行う方/);
  assert.match(top, /href="\/camp"/);
  assert.match(top, /href="\/user\/groups\?mode=fieldwork"/);
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
  assert.match(footer, /© 2026 ひらいずみ志業ポータル開発チーム/);
  assert.doesNotMatch(footer, /© 2026 平泉町/);
  assert.match(globalStyles, /color-scheme: light/);
  assert.doesNotMatch(globalStyles, /prefers-color-scheme:\s*dark/);
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
