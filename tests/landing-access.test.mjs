import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const page = await readFile(new URL("../app/page.js", import.meta.url), "utf8");
const css = await readFile(new URL("../app/page.module.css", import.meta.url), "utf8");

test("landing page places the supplied facility address below the existing content", () => {
  assert.match(page, /〒029-4102/);
  assert.match(page, /岩手県西磐井郡平泉町平泉字志羅山139番地8/);
  assert.match(page, /<address className=\{styles\.facilityAddress\}>/);
  assert.ok(page.indexOf('id="access-title"') > page.indexOf('id="assurance-title"'));
});

test("map link searches the encoded address and safely announces a new tab", () => {
  assert.match(page, /https:\/\/www\.google\.com\/maps\/search\/\?api=1&query=\$\{encodeURIComponent\(facilityAddress\)\}/);
  assert.match(page, /href=\{facilityMapUrl\} target="_blank" rel="noopener noreferrer"/);
  assert.match(page, /Googleマップで見る/);
  assert.match(page, /（別タブ）/);
});

test("access section reuses existing colors with wrapping and keyboard focus styling", () => {
  assert.match(css, /\.facilityAddress\s*\{[^}]*overflow-wrap: anywhere;/s);
  assert.match(css, /\.access a:focus-visible/);
  assert.match(css, /\.assurance,\s*\.access \{ width: calc\(100% - 24px\); \}/);
});
