import test from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const root = join(dirname(dirname(fileURLToPath(import.meta.url))), "public");
const pageNames = ["index.html", "work.html", "contact.html"];
const pages = Object.fromEntries(await Promise.all(pageNames.map(async name => [name, await readFile(join(root, name), "utf8")])));
const script = await readFile(join(root, "assets/script.js"), "utf8");
const css = await readFile(join(root, "assets/styles.css"), "utf8");

test("should_preserveErrorPageAndExposeThreePortfolioPages_when_openingThePortfolio", async () => {
  assert.deepEqual((await readdir(root)).filter(name => name.endsWith(".html")).sort(), [...pageNames, "404.html"].sort());
  const titles = new Set();
  for (const [name, html] of Object.entries(pages)) {
    assert.match(html, /<html lang="ko">/, name);
    assert.match(html, /name="viewport"/, name);
    assert.equal((html.match(/<h1(?:\s|>)/g) || []).length, 1, name);
    for (const tag of ["header", "main", "footer"]) assert.equal((html.match(new RegExp("<" + tag + "(?:\\s|>)", "g")) || []).length, 1, name);
    titles.add(html.match(/<title>([^<]+)<\/title>/)[1]);
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
    assert.equal(ids.length, new Set(ids).size, name + " has duplicate ids");
    for (const match of html.matchAll(/\b(?:for|aria-controls|aria-labelledby|aria-describedby)="([^"]+)"/g)) {
      for (const id of match[1].split(" ")) assert.ok(ids.includes(id), name + ": missing " + id);
    }
  }
  assert.equal(titles.size, 3);
});

test("should_resolveEveryRelativeLinkAndAsset_when_openingAnyPage", async () => {
  for (const [name, html] of Object.entries(pages)) {
    for (const match of html.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
      const reference = match[1];
      if (reference.startsWith("mailto:")) continue;
      const url = new URL(reference, "https://portfolio.local/" + name);
      assert.equal(url.origin, "https://portfolio.local", "Unexpected external resource");
      assert.equal(reference.startsWith("/"), false, "Resources must work as local files");
      const target = url.pathname.slice(1) || "index.html";
      assert.ok((await stat(join(root, target))).isFile(), name + ": " + reference);
      if (url.hash) {
        const targetHtml = pages[target];
        assert.ok(targetHtml?.includes('id="' + decodeURIComponent(url.hash.slice(1)) + '"'), name + ": " + reference);
      }
    }
  }
});

test("should_keepNavigationConsistent_when_movingBetweenPages", () => {
  for (const [name, html] of Object.entries(pages)) {
    const nav = html.match(/<nav id="site-nav"[\s\S]*?<\/nav>/)[0];
    assert.deepEqual([...nav.matchAll(/href="([^"]+)"/g)].map(match => match[1]), pageNames.map(page => "./" + page));
    assert.equal((nav.match(/aria-current="page"/g) || []).length, 1);
    assert.ok(nav.includes('href="./' + name + '" aria-current="page"'));
  }
});

test("should_preserveActualProjectFacts_when_renderingTheWorkPage", () => {
  const work = pages["work.html"];
  assert.deepEqual([...work.matchAll(/<article id="([^"]+)"/g)].map(match => match[1]), ["campaign", "social"]);
  for (const fact of ["2026.08.12 — 09.03", "2023.09 — 현재", "PDF 콘텐츠 구성·초안 제작 40%", "광고 영상 2편 편집 90%", "최고 조회수 약 112만 회", "콘텐츠 개선 이후 팔로워", "310명", "최종 PDF 편집과 디자인은 팀 결과물"]) {
    assert.ok(work.includes(fact), fact);
  }
  assert.equal((work.match(/class="case-study"/g) || []).length, 2);
  for (const phase of ["BACKGROUND", "INSIGHT", "ACTION", "RESULT"]) assert.equal((work.match(new RegExp("· " + phase, "g")) || []).length, 2);
  assert.match(pages["index.html"], /신입 콘텐츠 마케터/);
});

test("should_excludeUnfinishedContentAndUnsafeResources_when_shippingThePages", () => {
  for (const [name, html] of Object.entries(pages)) {
    assert.doesNotMatch(html, /자료 정리 중|확인 필요|미기재|확인 전|COVER IMAGE|The Big Shake|Meeko|Home II|Work II/, name);
    assert.doesNotMatch(html, /<style\b|\sstyle=|\son[a-z]+\s*=|javascript:|<script(?![^>]*\bsrc=)/i, name);
    for (const match of html.matchAll(/(?:href|action)="mailto:([^"?]+)[^"]*"/g)) assert.equal(match[1], "yuna12s@naver.com");
  }
  assert.doesNotMatch(script, /fetch\s*\(|XMLHttpRequest|localStorage|sessionStorage|document\.cookie|innerHTML/);
  assert.doesNotMatch(css, /@import|url\(["']?https?:/);
});

test("should_offerDirectEmailAndNativeDetails_when_javascriptIsUnavailable", () => {
  const contact = pages["contact.html"];
  assert.match(contact, /<noscript>[\s\S]*?mailto:yuna12s@naver\.com[\s\S]*?<\/noscript>/);
  assert.match(contact, /type="submit" disabled/);
  assert.match(contact, /action="mailto:yuna12s@naver\.com"/);
  assert.equal((contact.match(/<details>/g) || []).length, 3);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.match(css, /word-break: keep-all/);
  assert.match(css, /@media \(max-width: 767px\)/);
  assert.match(script, /min-width: 768px/);
});

function element() {
  const listeners = new Map();
  const classes = new Set();
  const attributes = new Map();
  return {
    value: "", textContent: "", disabled: false, focused: false, customValidity: "",
    classList: {
      add: value => classes.add(value),
      remove: value => classes.delete(value),
      contains: value => classes.has(value),
      toggle(value, force) {
        if (force ?? !classes.has(value)) classes.add(value); else classes.delete(value);
      },
    },
    addEventListener: (name, handler) => listeners.set(name, handler),
    emit: (name, event = {}) => listeners.get(name)?.(event),
    setAttribute: (name, value) => attributes.set(name, value),
    getAttribute: name => attributes.get(name),
    focus() { this.focused = true; },
    setCustomValidity(message) { this.customValidity = message; },
    closest: () => null,
    querySelector: () => null,
  };
}

function loadPage({ withForm = false, withMenu = false, hash = "", withObserver = false, reduce = false } = {}) {
  const locations = [];
  const desktop = element();
  desktop.matches = false;
  const motion = element();
  motion.matches = reduce;
  const nav = withMenu ? element() : null;
  const menu = withMenu ? element() : null;
  const firstLink = element();
  firstLink.closest = () => firstLink;
  if (nav) nav.querySelector = () => firstLink;
  if (menu) menu.setAttribute("aria-expanded", "false");

  const fields = [
    Object.assign(element(), { name: "name", type: "text", maxLength: 80 }),
    Object.assign(element(), { name: "email", type: "email", maxLength: 254 }),
    Object.assign(element(), { name: "message", type: "textarea", maxLength: 2000 }),
  ];
  const status = element();
  const submit = element();
  submit.disabled = true;
  const form = withForm ? element() : null;
  if (form) {
    form.querySelectorAll = () => fields;
    form.querySelector = selector => selector === "[data-form-status]" ? status : submit;
    form.elements = { namedItem: name => fields.find(field => field.name === name) };
    form.reportValidity = () => fields.every(field => !field.customValidity && field.value.trim() && (field.type !== "email" || /^[^\s@]+@[^\s@]+$/.test(field.value.trim())));
  }

  const details = { open: false };
  const project = element();
  project.querySelector = () => details;
  const above = element();
  above.getBoundingClientRect = () => ({ top: 100 });
  const below = element();
  below.getBoundingClientRect = () => ({ top: 1000 });
  const observed = [];
  let observer;
  class Observer {
    constructor(callback) { this.callback = callback; this.disconnected = false; observer = this; }
    observe(target) { observed.push(target); }
    unobserve(target) { observed.splice(observed.indexOf(target), 1); }
    disconnect() { this.disconnected = true; }
  }
  const document = Object.assign(element(), {
    documentElement: element(),
    querySelector: selector => ({ ".menu-toggle": menu, ".site-nav": nav, "[data-contact-form]": form })[selector] || null,
    querySelectorAll: () => withObserver ? [above, below] : [],
    getElementById: id => id === "campaign" ? project : null,
  });
  const window = Object.assign(element(), {
    innerHeight: 800,
    location: { hash, assign: url => locations.push(url) },
    matchMedia: query => query.includes("min-width") ? desktop : motion,
  });
  if (withObserver) window.IntersectionObserver = Observer;
  vm.runInNewContext(script, { document, window, IntersectionObserver: Observer });
  return { locations, desktop, motion, menu, nav, firstLink, fields, form, status, submit, document, window, details, above, below, observer };
}

test("should_runWithoutErrors_when_optionalPageControlsAreAbsent", () => {
  const page = loadPage();
  assert.equal(page.locations.length, 0);
  assert.ok(page.document.documentElement.classList.contains("js"));
});

test("should_closeMenuAndRestoreFocus_when_pressingEscapeOrChangingToDesktop", () => {
  const page = loadPage({ withMenu: true });
  page.menu.emit("click");
  assert.equal(page.menu.getAttribute("aria-expanded"), "true");
  assert.ok(page.firstLink.focused);
  page.document.emit("keydown", { key: "Escape" });
  assert.equal(page.menu.getAttribute("aria-expanded"), "false");
  assert.ok(page.menu.focused);
  page.menu.emit("click");
  page.desktop.matches = true;
  page.desktop.emit("change");
  assert.equal(page.nav.classList.contains("is-open"), false);
  page.menu.emit("click");
  page.nav.emit("click", { target: page.firstLink });
  assert.equal(page.menu.getAttribute("aria-expanded"), "false");
});

test("should_openCaseStudy_when_enteringThroughAProjectLink", () => {
  const page = loadPage({ hash: "#campaign" });
  assert.equal(page.details.open, true);
  assert.doesNotThrow(() => loadPage({ hash: "#%not-an-id" }));
});

function validForm() {
  const page = loadPage({ withForm: true });
  ["채용 담당자", "recruiter@example.com", "안녕하세요.\n포트폴리오 관련 문의입니다."].forEach((value, index) => page.fields[index].value = value);
  return page;
}

test("should_composeEncodedEmailWithoutClearingInputs_when_submittingValidKoreanText", () => {
  const page = validForm();
  let prevented = false;
  page.form.emit("submit", { preventDefault() { prevented = true; } });
  assert.ok(prevented);
  assert.equal(page.submit.disabled, false);
  assert.equal(page.locations.length, 1);
  const url = new URL(page.locations[0]);
  assert.equal(url.protocol, "mailto:");
  assert.equal(url.pathname, "yuna12s@naver.com");
  assert.equal(url.searchParams.get("subject"), "[포트폴리오 문의] 채용 담당자");
  assert.equal(url.searchParams.get("body"), "이름: 채용 담당자\n회신 이메일: recruiter@example.com\n\n안녕하세요.\n포트폴리오 관련 문의입니다.");
  assert.equal(page.fields[2].value, "안녕하세요.\n포트폴리오 관련 문의입니다.");
  assert.doesNotMatch(page.status.textContent, /(?:전송|발송) 완료/);
});

test("should_keepSpecialCharactersInsideTheBody_when_composingAMailtoLink", () => {
  const page = validForm();
  const message = "문의 &bcc=someone@example.com #자료 + 100%\n<내용>";
  page.fields[2].value = message;
  page.form.emit("submit", { preventDefault() {} });
  const url = new URL(page.locations[0]);
  assert.deepEqual([...url.searchParams.keys()], ["subject", "body"]);
  assert.ok(url.searchParams.get("body").endsWith(message));
});

for (const [label, index, value] of [
  ["emptyName", 0, ""], ["blankMessage", 2, "   "], ["invalidEmail", 1, "invalid"],
  ["overlongName", 0, "이".repeat(81)], ["overlongMessage", 2, "한".repeat(2001)],
]) {
  test("should_blockMailDraft_when_" + label, () => {
    const page = validForm();
    page.fields[index].value = value;
    page.form.emit("submit", { preventDefault() {} });
    assert.equal(page.locations.length, 0);
    assert.match(page.status.textContent, /확인/);
    page.fields[index].emit("input");
    assert.equal(page.fields[index].customValidity, "");
    assert.equal(page.status.textContent, "");
  });
}

test("should_acceptTheDocumentedMessageLimit_when_composingADraft", () => {
  const page = validForm();
  page.fields[2].value = "한".repeat(2000);
  page.form.emit("submit", { preventDefault() {} });
  assert.equal(page.locations.length, 1);
  assert.ok(new URL(page.locations[0]).searchParams.get("body").endsWith("한".repeat(2000)));
});

test("should_keepContentVisible_when_reducedMotionIsEnabledOrChanges", () => {
  const initial = loadPage({ withObserver: true, reduce: true });
  assert.equal(initial.below.classList.contains("reveal-ready"), false);
  const page = loadPage({ withObserver: true });
  assert.equal(page.above.classList.contains("reveal-ready"), false);
  assert.equal(page.below.classList.contains("reveal-ready"), true);
  page.observer.callback([{ target: page.below, isIntersecting: true }]);
  assert.equal(page.below.classList.contains("reveal-ready"), false);
  page.motion.matches = true;
  page.motion.emit("change");
  assert.ok(page.observer.disconnected);
  assert.equal(page.above.classList.contains("reveal-ready"), false);
});
