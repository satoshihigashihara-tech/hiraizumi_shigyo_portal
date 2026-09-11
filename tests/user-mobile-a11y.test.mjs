import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("root loading, error and not-found boundaries provide meaningful recovery UI", async () => {
  const [loading, error, notFound, styles] = await Promise.all([
    read("app/loading.js"),
    read("app/error.js"),
    read("app/not-found.js"),
    read("app/Boundary.module.css"),
  ]);

  assert.match(loading, /role="status"/);
  assert.match(loading, /画面を読み込んでいます/);
  assert.match(error, /^"use client"/);
  assert.match(error, /onClick=\{\(\) => retry\(\)\}/);
  assert.match(error, /type="button"/);
  assert.doesNotMatch(error, /error\.message|error\.stack|error\.digest/);
  assert.match(notFound, /ページが見つかりません/);
  assert.match(notFound, /href="\/"/);
  assert.match(styles, /@media \(max-width: 480px\)/);
  assert.match(styles, /flex-wrap: wrap/);
});

test("shared form and navigation foundations retain labels, pending text and visible focus", async () => {
  const [field, submit, pageShellStyles, userLayout, userLayoutStyles] =
    await Promise.all([
      read("app/components/FormField.js"),
      read("app/components/SubmitButton.js"),
      read("app/components/PageShell.module.css"),
      read("app/user/layout.js"),
      read("app/user/layout.module.css"),
    ]);

  assert.match(field, /<label/);
  assert.match(field, /<fieldset/);
  assert.match(field, /<legend/);
  assert.match(field, /aria-describedby/);
  assert.match(field, /aria-invalid/);
  assert.match(submit, /useFormStatus/);
  assert.match(submit, /aria-busy=\{isPending\}/);
  assert.match(pageShellStyles, /:focus-visible/);
  assert.match(pageShellStyles, /outline: 3px solid/);
  assert.match(userLayout, /href="#user-main"/);
  assert.match(userLayout, /<nav[^>]+aria-label="利用者メニュー"/);
  assert.match(userLayoutStyles, /:focus-visible/);
  assert.match(userLayoutStyles, /flex-wrap: wrap/);
});

test("all user route CSS uses shared narrow-screen containment", async () => {
  const files = [
    "app/components/PageShell.module.css",
    "app/user/layout.module.css",
    "app/user/page.module.css",
    "app/user/applications/page.module.css",
    "app/user/applications/new/page.module.css",
    "app/user/applications/new/camp/page.module.css",
    "app/user/applications/[applicationId]/application-view.module.css",
    "app/user/applications/[applicationId]/page.module.css",
    "app/user/applications/[applicationId]/edit/page.module.css",
  ];
  const contents = await Promise.all(files.map(read));
  for (const [index, css] of contents.entries()) {
    assert.match(
      css,
      /@media \((?:max-width: 599px|min-width: 600px|max-width: 480px)|flex-wrap: wrap|overflow-wrap: anywhere/,
      files[index],
    );
  }
  assert.match(contents[0], /overflow-wrap: anywhere/);
  assert.match(contents[0], /\.shell \* \{\s*min-width: 0/);
});
