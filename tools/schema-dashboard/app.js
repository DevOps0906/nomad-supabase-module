"use strict";
// 정적 대시보드. 데이터: data/schema.json(생성기 scripts/schema-dashboard.py) 우선, 없으면 sample-data.json — ?data=<경로> 로 지정. 사용자 데이터는 textContent로만 넣는다.
const VARIANTS = [["existing", "기존"], ["single", "단일"], ["tenant", "테넌트"], ["monorepo", "모노레포"], ["isolated", "격리형"], ["local", "로컬 저장소"]];
const OWNERS = { user: "user", org: "org", public: "공개", server: "서버", indirect: "간접" };
const CLIENTS = { web: "웹", app: "앱", desktop: "데스크톱", worker: "워커" };
const THEME_KEY = "nomad.theme";

const state = { data: null, filters: { schema: "", owner: "", noRls: false, client: "" }, q: "", navQ: "", navOpen: new Map() }; // navOpen: 분류 key → 사용자가 정한 펼침(true/false)
const $main = document.getElementById("main");
const $nav = document.getElementById("nav");

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v == null) continue;
    if (k === "class") el.className = v; else if (k.startsWith("on")) el.addEventListener(k.slice(2), v); else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return el;
}
const badge = (text, kind) => h("span", { class: "badge" + (kind ? " badge--" + kind : "") }, text);

/* ---------- SQL 보기(구문 강조는 span+CSS, 복사·다운로드) ---------- */
const SQL_KW = new Set(("create alter drop table index unique policy trigger function or replace if not exists on for to using with check " +
  "select insert update delete from where into values as grant revoke execute all enable disable row level security references primary key foreign " +
  "default null returns language security definer set search_path begin end return returning cascade restrict constraint add column rename " +
  "comment is view schema extension type enum do declare loop case when then else and in order by group limit join left inner cross unlogged " +
  "after before each statement generated always stored identity true false only").split(" "));
const SQL_TOKEN = /(--[^\n]*)|(\/\*[\s\S]*?\*\/)|('(?:[^']|'')*')|(\$(?:[A-Za-z_]\w*)?\$)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)/g;
function highlightSql(sql) {
  const frag = document.createDocumentFragment();
  const put = (text, cls) => { if (!text) return; if (cls) frag.append(h("span", { class: cls }, text)); else frag.append(document.createTextNode(text)); };
  let last = 0, m;
  SQL_TOKEN.lastIndex = 0;
  while ((m = SQL_TOKEN.exec(sql))) {
    put(sql.slice(last, m.index));
    const t = m[0];
    if (m[1] || m[2]) put(t, "sql-c"); else if (m[3]) put(t, "sql-s"); else if (m[4]) put(t, "sql-d"); else if (m[5]) put(t, "sql-n");
    else put(t, SQL_KW.has(t.toLowerCase()) ? "sql-k" : null);
    last = m.index + t.length;
  }
  put(sql.slice(last));
  return frag;
}
function copyText(text, btn) {
  const done = (ok) => { const old = btn.textContent; btn.textContent = ok ? "복사됨" : "복사 실패"; setTimeout(() => { btn.textContent = old; }, 1500); };
  if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(() => done(true), () => done(false)); return; }
  const ta = h("textarea", { "aria-hidden": "true", style: "position:fixed;opacity:0" }); ta.value = text; document.body.append(ta); ta.select();
  let ok = false; try { ok = document.execCommand("copy"); } catch (e) { ok = false; } ta.remove(); done(ok);
}
function downloadText(text, filename) {
  const a = h("a", { href: URL.createObjectURL(new Blob([text], { type: "application/sql;charset=utf-8" })), download: filename });
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
const baseName = (p) => String(p).split("/").pop();
function sqlViewer(title, sql, filename) {
  const lines = sql.split("\n").length;
  const code = h("code", {});
  code.append(highlightSql(sql));
  const copyBtn = h("button", { type: "button", class: "btn", onclick: () => copyText(sql, copyBtn) }, "복사");
  return h("div", { class: "sqlview" },
    h("div", { class: "sqlview__bar" }, h("span", { class: "mono sqlview__title" }, title), h("span", { class: "muted" }, lines + "줄"),
      copyBtn, filename ? h("button", { type: "button", class: "btn", onclick: () => downloadText(sql, filename) }, "다운로드") : null),
    h("pre", { class: "sqlview__pre", tabindex: "0", role: "region", "aria-label": title + " SQL 원문" }, code));
}
// SQL 카드 격자. groups: [{name, mono?, items:[{title,sub?,desc?,sql|src,filename,badges?}]}] — src는 열 때 불러오는 같은 출처 경로(번들)
const countRe = (sql, re) => (sql.match(re) || []).length;
function sqlStats(sql) {
  return [["테이블", /\bcreate\s+(?:unlogged\s+)?table\b/gi], ["함수", /\bcreate\s+(?:or\s+replace\s+)?function\b/gi], ["정책", /\bcreate\s+policy\b/gi]]
    .map(([l, re]) => [l, countRe(sql, re)]).filter(([, n]) => n > 0);
}
function sqlSummary(sql) {
  // 첫 한국어/설명 주석 줄(되돌림 안내 제외)을 카드 요약으로
  for (const line of sql.split("\n")) {
    const m = line.match(/^\s*--\s*(.+)$/);
    if (m && !/^되돌림/.test(m[1]) && !/^[─=\-\s]+$/.test(m[1])) return m[1].replace(/^[─\s]+|[─\s]+$/g, "");
  }
  return "";
}
function sqlCards(groups) {
  // 카드를 누르면 모달 대화상자(<dialog>)로 원문이 바로 열린다. Esc·닫기·바깥 클릭으로 닫고, 닫으면 누른 카드로 포커스가 돌아간다
  const dlg = h("dialog", { class: "sqldialog", "aria-label": "SQL 원문" });
  dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
  let trigger = null;
  dlg.addEventListener("close", () => { dlg.replaceChildren(); if (trigger && trigger.isConnected) trigger.focus(); });
  const open = (item, btn) => {
    trigger = btn;
    const closeBtn = h("button", { type: "button", class: "btn", onclick: () => dlg.close() }, "닫기");
    const show = (sql) => {
      const viewer = sqlViewer(item.title, sql, item.filename);
      viewer.querySelector(".sqlview__bar").append(closeBtn);
      dlg.replaceChildren(viewer);
      closeBtn.focus();
    };
    if (item.sql != null) show(item.sql);
    else dlg.replaceChildren(h("div", { class: "sqlview" }, h("div", { class: "sqlview__bar" }, h("span", { class: "mono sqlview__title" }, item.title), h("span", { class: "muted", role: "status" }, "불러오는 중…"), closeBtn)));
    dlg.showModal();
    closeBtn.focus();
    if (item.sql == null) fetch(item.src).then((res) => { if (!res.ok) throw new Error("HTTP " + res.status); return res.text(); })
      .then((t) => { item.sql = t; if (dlg.open && trigger === btn) show(t); })
      .catch((err) => { if (dlg.open && trigger === btn) dlg.querySelector('[role="status"]').textContent = "불러오지 못했습니다 (" + err.message + ")"; });
  };
  // 카드 = 제목·경로·설명(content의 summary, 없으면 첫 주석)·구성(parts, 접이식)·통계 + "SQL 보기" 버튼
  const card = (item, mono) => h("li", {}, h("article", { class: "sqlcard" },
    h("h4", { class: "sqlcard__title" + (mono ? " mono" : "") }, item.title),
    item.sub ? h("span", { class: "sqlcard__sub muted" }, item.sub) : null,
    item.doc && item.doc.summary ? h("p", { class: "sqlcard__summary" }, item.doc.summary) : item.desc ? h("span", { class: "sqlcard__desc" }, item.desc) : null,
    item.doc ? docParts(item.doc.parts) : null,
    h("span", { class: "sqlcard__meta" }, item.badges ? item.badges.map((b) => badge(b)) : [badge(item.sql.split("\n").length + "줄"), sqlStats(item.sql).map(([l, n]) => badge(l + " " + n))]),
    h("button", { type: "button", class: "btn sqlcard__open", "aria-haspopup": "dialog", "aria-label": item.title + " SQL 보기", onclick: (e) => open(item, e.currentTarget) }, "SQL 보기")));
  return h("div", { class: "sqlcards" },
    groups.map((g) => g.items.length ? h("section", { class: "sqlcards__group" },
      h("h3", {}, g.name, h("span", { class: "count muted" }, g.items.length)),
      h("ul", { class: "sqlcards__grid", "aria-label": g.name }, g.items.map((it) => card(it, g.mono)))) : null),
    dlg);
}

// content 설명의 parts: [{title, items:[[이름, 설명]]}] → 접이식 목록(카드 높이를 낮게 유지)
function docParts(parts) {
  if (!Array.isArray(parts) || !parts.length) return null;
  return h("div", { class: "parts" }, parts.map((pt, i) => {
    const items = Array.isArray(pt.items) ? pt.items : [];
    return h("details", { class: "parts__group", open: i === 0 },
      h("summary", {}, pt.title || "구성", h("span", { class: "count muted" }, items.length)),
      h("ul", { class: "parts__list" }, items.map((it) => {
        const [name, desc] = Array.isArray(it) ? it : [String(it), ""];
        return h("li", {}, h("code", {}, name), desc ? [" — ", desc] : null);
      })));
  }));
}

/* ---------- 구조도(Mermaid, 고정 버전 CDN · securityLevel strict · 실패 시 원문) ---------- */
const MERMAID_SRC = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js";
const MERMAID_SRI = "sha384-rbtjAdnIQE/aQJGEgXrVUlMibdfTSa4PQju4HDhN3sR2PmaKFzhEafuePsl9H/9I";
let mermaidP = null, mmdSeq = 0, mmdChain = Promise.resolve(), mmdTheme = null;
const svgCache = new Map(); // 테마+원문 → svg 문자열(탭 이동 때 다시 그리지 않음)
function loadMermaid() {
  if (!mermaidP) mermaidP = new Promise((resolve, reject) => {
    const s = h("script", { src: MERMAID_SRC, integrity: MERMAID_SRI, crossorigin: "anonymous", referrerpolicy: "no-referrer" });
    s.addEventListener("load", () => (window.mermaid ? resolve(window.mermaid) : reject(new Error("mermaid 전역 없음"))));
    s.addEventListener("error", () => { mermaidP = null; s.remove(); reject(new Error("Mermaid 스크립트를 불러오지 못했습니다")); });
    document.head.append(s);
  });
  return mermaidP;
}
const isDark = () => { const t = document.documentElement.getAttribute("data-theme"); return t ? t === "dark" : matchMedia("(prefers-color-scheme: dark)").matches; };
function mmdFallback(box, err) {
  box.replaceChildren(h("p", { class: "muted diagram__err", role: "note" }, "구조도를 그리지 못해 원문을 표시합니다 (" + err.message + ")"),
    h("pre", { class: "diagram__src" }, h("code", {}, box._mmd)));
}
function drawMermaid(box) {
  box.replaceChildren(h("p", { class: "muted" }, "구조도 그리는 중…"));
  mmdChain = mmdChain.then(async () => {
    if (!box.isConnected) return;
    const theme = isDark() ? "dark" : "default";
    const key = theme + "\n" + box._mmd;
    // mermaid 출력은 securityLevel strict(DOMPurify 정화)를 거친 SVG만 넣는다 — 이 화면에서 유일한 innerHTML
    if (svgCache.has(key)) { box.innerHTML = svgCache.get(key); return; }
    const id = "mmd-" + (++mmdSeq);
    try {
      const m = await loadMermaid();
      if (mmdTheme !== theme) { m.initialize({ startOnLoad: false, securityLevel: "strict", theme, fontFamily: getComputedStyle(document.body).fontFamily }); mmdTheme = theme; }
      const { svg } = await m.render(id, box._mmd);
      svgCache.set(key, svg);
      if (box.isConnected) box.innerHTML = svg;
    } catch (err) {
      document.querySelectorAll("#d" + id + ", #" + id).forEach((el) => { if (!box.contains(el)) el.remove(); }); // 실패 시 mermaid가 body에 남기는 임시 요소
      if (box.isConnected) mmdFallback(box, err);
    }
  });
}
function redrawDiagrams() { document.querySelectorAll(".diagram__box").forEach(drawMermaid); }
function diagramBox(title, src) {
  const box = h("div", { class: "diagram__box", tabindex: "0", role: "region", "aria-label": title + " 구조도" });
  box._mmd = src;
  queueMicrotask(() => drawMermaid(box)); // render()가 화면에 붙인 뒤 그린다
  return box;
}
// 표 관계 ERD: 표·FK로 erDiagram(컬럼은 PK/FK만). 바깥 스키마 표(nomad_core·auth 등)는 참조된 컬럼만 가진 엔터티로
const mmdId = (s) => String(s).replace(/[^A-Za-z0-9_]/g, "_");
function erdSource(tables) {
  if (!tables.length) return null;
  const nameCount = {};
  tables.forEach((t) => { nameCount[t.name] = (nameCount[t.name] || 0) + 1; });
  const own = new Map(tables.map((t) => [t.schema + "." + t.name, mmdId(nameCount[t.name] > 1 ? t.schema + "_" + t.name : t.name)]));
  const ext = new Map(); // id → Set(컬럼)
  const lines = ["erDiagram"], rels = [];
  for (const t of tables) {
    const me = own.get(t.schema + "." + t.name);
    const cols = (t.columns || []).filter((c) => c.pk || c.fk);
    lines.push("  " + me + (cols.length ? " {" : ""));
    for (const c of cols) {
      const typ = mmdId(String(c.type || "col").split(/[\s(]/)[0]) || "col";
      lines.push("    " + (/^[A-Za-z]/.test(typ) ? typ : "t" + typ) + " " + mmdId(c.name) + " " + (c.pk && c.fk ? "PK, FK" : c.pk ? "PK" : "FK"));
      if (!c.fk) continue;
      const parts = c.fk.split(".");
      const col = parts.pop(), target = parts.join(".");
      let pid = own.get(target);
      if (!pid) { pid = mmdId(target); if (!ext.has(pid)) ext.set(pid, new Set()); ext.get(pid).add(mmdId(col)); }
      rels.push("  " + pid + " ||--o{ " + me + ' : "' + mmdId(c.name) + '"');
    }
    if (cols.length) lines.push("  }");
  }
  for (const [id, cols] of ext) lines.push("  " + id + " {", ...[...cols].map((c) => "    ref " + c + " PK"), "  }");
  return lines.concat(rels).join("\n");
}
// 구조도 섹션: content의 diagrams + 자동 ERD. erd = {title, tables}
function diagramSection(doc, erd) {
  const list = ((doc && Array.isArray(doc.diagrams)) ? doc.diagrams : []).filter((d) => d && d.mermaid).map((d) => ({ title: d.title || "구조도", src: d.mermaid }));
  const erdSrc = erd ? erdSource(erd.tables) : null;
  if (erdSrc) list.push({ title: erd.title, src: erdSrc, note: "컬럼은 PK/FK만 · 바깥 스키마 표는 참조된 컬럼만" });
  if (!list.length) return null;
  return h("section", { class: "diagrams", "aria-label": "구조도" },
    h("h3", { class: "diagrams__title" }, "구조도"),
    list.map((d) => h("figure", { class: "diagram" },
      h("figcaption", {}, d.title, d.note ? h("small", { class: "muted" }, d.note) : null),
      diagramBox(d.title, d.src))));
}
// 화면 머리: 아이콘·이름·배지·tagline·메타 + overview
function docHead(doc, title, extra, meta) {
  doc = doc || {};
  return [h("div", { class: "page-head" },
    h("h2", {}, doc.icon ? h("span", { class: "page-head__icon", "aria-hidden": "true" }, doc.icon) : null, title), extra,
    doc.tagline ? h("p", { class: "page-head__tagline" }, doc.tagline) : null,
    h("p", {}, meta)),
  doc.overview ? h("p", { class: "overview" }, doc.overview) : null];
}

/* ---------- 테마 ---------- */
function currentTheme() { try { return localStorage.getItem(THEME_KEY) || "system"; } catch (e) { return "system"; } }
function applyTheme(t) {
  const root = document.documentElement;
  if (t === "light" || t === "dark") root.setAttribute("data-theme", t); else root.removeAttribute("data-theme");
  try { if (t === "system") localStorage.removeItem(THEME_KEY); else localStorage.setItem(THEME_KEY, t); } catch (e) { /* 저장 불가여도 즉시 적용은 유지 */ }
  document.querySelectorAll("[data-theme-set]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.themeSet === t)));
  redrawDiagrams();
}
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { if (!document.documentElement.hasAttribute("data-theme")) redrawDiagrams(); });
document.querySelectorAll("[data-theme-set]").forEach((b) => b.addEventListener("click", () => applyTheme(b.dataset.themeSet)));
// 초기 표시: theme-init.js가 이미 적용한 상태를 버튼에 반영만 한다(?theme=는 저장하지 않는 임시 지정)
const shown = document.documentElement.getAttribute("data-theme") || "system";
document.querySelectorAll("[data-theme-set]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.themeSet === shown)));

/* ---------- 라우팅: #core · #category/<key> · #product/<slug>/<tab> · #compare (앞의 "/"는 무시: #/category/media) ---------- */
function route() {
  const p = (location.hash || "#core").slice(1).replace(/^\/+/, "").split("/");
  return { type: p[0] || "core", slug: p[1], tab: p[2] || "existing" };
}
function go(hash) { location.hash = hash; }

// 내비 뼈대는 한 번만 만든다(검색 입력 포커스 유지). 모바일(~767)은 "메뉴" 버튼으로 접고 편다
const $navCurrent = h("span", { class: "nav__current muted" });
const $navToggle = h("button", { type: "button", class: "nav__toggle", "aria-expanded": "false", "aria-controls": "nav-body" }, "메뉴", $navCurrent);
const $navQ = h("input", { type: "search", placeholder: "제품 검색", autocomplete: "off" });
const $navList = h("div", { class: "nav__list" });
$nav.append($navToggle, h("div", { class: "nav__body", id: "nav-body" }, h("label", { class: "nav__search" }, h("span", { class: "sr-only" }, "제품 검색"), $navQ), $navList));
const setNavOpen = (on) => { $nav.classList.toggle("is-open", on); $navToggle.setAttribute("aria-expanded", String(on)); };
$navToggle.addEventListener("click", () => setNavOpen(!$nav.classList.contains("is-open")));
$navQ.addEventListener("input", () => { state.navQ = $navQ.value.trim().toLowerCase(); if (state.data) renderNav(route()); });

function navCategories() {
  const bySlug = new Map(state.data.products.map((p) => [p.slug, p]));
  const used = new Set();
  const cats = (state.data.categories || []).map((c) => {
    const products = (c.products || []).map((s) => bySlug.get(s)).filter((p) => p && !used.has(p.slug));
    products.forEach((p) => used.add(p.slug));
    return { key: c.key, icon: c.icon, name: c.name, products };
  });
  const rest = state.data.products.filter((p) => !used.has(p.slug));
  if (rest.length) cats.push({ key: "_etc", icon: "📦", name: cats.length ? "기타" : "제품", products: rest });
  return cats.filter((c) => c.products.length);
}
function renderNav(r) {
  const q = state.navQ;
  const item = (icon, label, sub, hash, on) => h("button", { type: "button", class: "nav__item", "aria-current": on ? "page" : false, onclick: () => { setNavOpen(false); go(hash); } },
    h("span", { class: "nav__icon", "aria-hidden": "true" }, icon || "•"),
    h("span", { class: "nav__text" }, label, sub ? h("small", {}, sub) : null));
  const doc = (p) => p.doc || {};
  const hit = (p) => !q || [p.name, p.slug, doc(p).tagline].join(" ").toLowerCase().includes(q);
  const cur = r.type === "product" ? state.data.products.find((p) => p.slug === r.slug) : null;
  const cats = navCategories();
  const curCat = r.type === "category" ? cats.find((c) => c.key === r.slug) : null;
  $navCurrent.textContent = cur ? cur.name : curCat ? curCat.name : r.type === "compare" ? "제품 × 구조" : "nomad_core";
  // 분류 그룹: 이름 버튼 = 분류 화면으로 이동 + 펼침, 화살표 버튼 = 접기·펴기만. 기본 펼침 = 검색 중 · 현재 제품/분류
  const groups = cats.map((c, i) => {
    const ps = c.products.filter(hit);
    if (!ps.length) return null;
    const auto = Boolean(q) || ps.includes(cur) || c === curCat;
    const open = state.navOpen.has(c.key) ? state.navOpen.get(c.key) : auto;
    const bodyId = "nav-group-" + i;
    const body = h("div", { class: "nav__groupbody", id: bodyId, hidden: !open }, ps.map((p) => item(doc(p).icon, p.name, doc(p).tagline, "#product/" + p.slug + "/existing", p === cur)));
    const arrow = h("button", { type: "button", class: "nav__arrow", "aria-expanded": String(open), "aria-controls": bodyId, "aria-label": c.name + " 접기·펴기" });
    arrow.addEventListener("click", () => {
      const on = body.hidden;
      body.hidden = !on; arrow.setAttribute("aria-expanded", String(on)); state.navOpen.set(c.key, on);
    });
    return h("div", { class: "nav__group" },
      h("div", { class: "nav__grouphead" },
        h("button", { type: "button", class: "nav__groupbtn", "aria-current": c === curCat ? "page" : false,
          onclick: () => { state.navOpen.set(c.key, true); setNavOpen(false); go("#category/" + c.key); } },
          h("span", { class: "nav__icon", "aria-hidden": "true" }, c.icon || "•"), h("span", { class: "nav__groupname" }, c.name), h("span", { class: "count muted" }, ps.length)),
        arrow),
      body);
  }).filter(Boolean);
  $navList.replaceChildren(
    h("span", { class: "nav__label" }, "공용 모듈"),
    item((state.data.core.doc || {}).icon || "🧩", "nomad_core", (state.data.core.doc || {}).tagline, "#core", r.type === "core"),
    h("span", { class: "nav__label" }, "제품"),
    ...(groups.length ? groups : [h("p", { class: "muted nav__empty" }, "맞는 제품이 없습니다.")]),
    h("span", { class: "nav__label" }, "비교"),
    item("📊", "제품 × 구조", null, "#compare", r.type === "compare"));
}

/* ---------- 분류 화면: 제품 카드 격자(아이콘·이름·tagline·형태·표 수), 누르면 제품 화면 ---------- */
const FORM_LABEL = { user: "user형", org: "org형", isolated: "격리형" };
const FORM_VARIANT = { user: "single", org: "tenant", isolated: "isolated" }; // 표 수는 제품 형태의 대표 구조로
function viewCategory(r) {
  const c = navCategories().find((x) => x.key === r.slug);
  state.redraw = () => {};
  if (!c) return h("div", { class: "notice" }, "알 수 없는 분류: " + r.slug);
  const vname = Object.fromEntries(VARIANTS);
  const card = (p) => {
    const doc = p.doc || {};
    const vk = (p.variants[FORM_VARIANT[p.form]] || { tables: [] }).tables.length ? FORM_VARIANT[p.form] : "existing";
    const n = (p.variants[vk] || { tables: [] }).tables.length;
    return h("li", {}, h("button", { type: "button", class: "prodcard", onclick: () => go("#product/" + p.slug + "/existing") },
      h("span", { class: "prodcard__head" }, h("span", { class: "prodcard__icon", "aria-hidden": "true" }, doc.icon || "•"), h("span", { class: "prodcard__name" }, p.name)),
      doc.tagline ? h("span", { class: "prodcard__tagline" }, doc.tagline) : null,
      h("span", { class: "prodcard__meta" }, badge(FORM_LABEL[p.form] || p.form, "accent"), badge("표 " + n + " · " + vname[vk]))));
  };
  return [h("div", { class: "page-head" },
      h("h2", {}, h("span", { class: "page-head__icon", "aria-hidden": "true" }, c.icon || "•"), c.name), badge("제품 " + c.products.length + "개"),
      h("p", {}, "분류 · 카드를 누르면 그 제품 화면으로 이동")),
    h("ul", { class: "prodcards", "aria-label": c.name + " 제품" }, c.products.map(card))];
}

/* ---------- 필터·검색 ---------- */
function matches(t) {
  const f = state.filters;
  if (f.schema && t.schema !== f.schema) return false;
  if (f.owner && t.owner !== f.owner) return false;
  if (f.noRls && t.rls) return false;
  if (f.client && !(t.used_by || []).includes(f.client)) return false;
  if (state.q) {
    const q = state.q.toLowerCase();
    const hay = [t.name, t.schema, t.comment, t.renamed_from, ...(t.columns || []).map((c) => c.name)].join(" ").toLowerCase();
    if (!hay.includes(q)) return false;
  }
  return true;
}
function filterBar(tables, rerender) {
  const schemas = [...new Set(tables.map((t) => t.schema))].sort();
  const sel = (label, key, opts) => h("label", {}, label,
    h("select", { onchange: (e) => { state.filters[key] = e.target.value; rerender(); } },
      h("option", { value: "" }, "전체"),
      opts.map(([v, l]) => h("option", { value: v, selected: state.filters[key] === v }, l))));
  return h("div", { class: "filters", role: "group", "aria-label": "필터" },
    sel("스키마", "schema", schemas.map((s) => [s, s])),
    sel("소유", "owner", Object.entries(OWNERS)),
    sel("사용처", "client", Object.entries(CLIENTS)),
    h("label", {}, h("input", { type: "checkbox", checked: state.filters.noRls, onchange: (e) => { state.filters.noRls = e.target.checked; rerender(); } }), "RLS 없음만"));
}

/* ---------- 테이블 행 ---------- */
function tableRow(t) {
  const meta = [
    badge(OWNERS[t.owner] || t.owner, t.owner === "org" || t.owner === "user" ? "accent" : ""),
    badge(t.rls ? "RLS" : "RLS 없음", t.rls ? "ok" : "danger"),
    (t.used_by || []).map((c) => badge(CLIENTS[c] || c)),
    t.sync ? badge("동기화 updated_at·deleted_at", "warn") : null,
  ];
  const cols = t.columns || [];
  const info = h("div", {},
    h("dl", {}, h("dt", {}, "출처"), h("dd", { class: "mono" }, t.source_file || "-"),
      t.comment ? [h("dt", {}, "설명"), h("dd", {}, t.comment)] : null),
    h("h4", {}, "컬럼 (" + cols.length + ")"),
    cols.length ? h("div", { class: "scroll", role: "region", "aria-label": t.name + " 컬럼", tabindex: "0" }, h("table", {},
      h("thead", {}, h("tr", {}, ["이름", "타입", "null", "PK", "FK"].map((x) => h("th", { scope: "col" }, x)))),
      h("tbody", {}, cols.map((c) => h("tr", {},
        h("td", { class: "mono" }, c.name), h("td", { class: "mono" }, c.type), h("td", {}, c.nullable ? "예" : "-"),
        h("td", {}, c.pk ? "PK" : "-"), h("td", { class: "mono" }, c.fk || "-")))))) : h("p", { class: "muted" }, "컬럼 정보 없음(자리표시)"),
    h("h4", {}, "정책 (" + (t.policies || []).length + ")"),
    (t.policies || []).length ? h("div", { class: "scroll", role: "region", "aria-label": t.name + " 정책", tabindex: "0" }, h("table", {},
      h("thead", {}, h("tr", {}, ["이름", "명령", "역할"].map((x) => h("th", { scope: "col" }, x)))),
      h("tbody", {}, t.policies.map((p) => h("tr", {}, h("td", { class: "mono" }, p.name), h("td", {}, p.cmd), h("td", {}, (p.roles || []).join(", "))))))) : h("p", { class: "muted" }, t.rls ? "정책 없음(기본 거부)" : "RLS 꺼짐"));
  const sqlPane = h("div", { hidden: true });
  const tabBtn = (label, on) => h("button", { type: "button", "aria-pressed": String(on) }, label);
  const b1 = tabBtn("구조", true), b2 = tabBtn("SQL", false);
  const pick = (sqlOn) => {
    b1.setAttribute("aria-pressed", String(!sqlOn)); b2.setAttribute("aria-pressed", String(sqlOn));
    info.hidden = sqlOn; sqlPane.hidden = !sqlOn;
    if (sqlOn && !sqlPane.firstChild) sqlPane.append(t.sql ? sqlViewer(t.schema + "." + t.name, t.sql, t.name + ".sql") : h("p", { class: "muted" }, "SQL 없음(샘플 데이터)"));
  };
  b1.addEventListener("click", () => pick(false)); b2.addEventListener("click", () => pick(true));
  const body = h("div", { class: "row__body" }, h("div", { class: "tabs tabs--sub", role: "group", "aria-label": t.name + " 보기" }, b1, b2), info, sqlPane);
  return h("details", { class: "row" },
    h("summary", {},
      h("span", { class: "row__name" }, h("span", { class: "mono" }, t.name), h("small", {}, t.schema)),
      h("span", { class: "row__meta" }, meta),
      t.renamed_from ? h("span", { class: "row__rename" }, "기존 → 새: ", h("span", { class: "mono" }, t.renamed_from + " → " + t.schema + "." + t.name)) : null),
    body);
}
const rowList = (tables, openFirst) => tables.length ? h("div", { class: "rows" }, tables.map((t, i) => { const el = tableRow(t); if (openFirst && i === 0) el.open = true; return el; })) : h("div", { class: "empty" }, "조건에 맞는 테이블이 없습니다.");

function fnRow(f) {
  const body = h("div", { class: "row__body" });
  const d = h("details", { class: "row" },
    h("summary", {}, h("span", { class: "row__name" }, h("span", { class: "mono" }, f.name), h("small", {}, f.schema)),
      h("span", { class: "row__meta" }, f.security_definer ? badge("definer", "warn") : null, (f.grants || []).map((g) => badge(g)))), body);
  d.addEventListener("toggle", () => { if (d.open && !body.firstChild) body.append(f.sql ? sqlViewer(f.schema + "." + f.name, f.sql, f.name + ".sql") : h("p", { class: "muted" }, "SQL 없음(샘플 데이터)")); });
  return d;
}

/* ---------- 화면 ---------- */
// 영역 SQL = 그 영역 테이블 SQL + 함수 본문을 이어 붙인 것(생성기가 sql을 넣은 경우만, 없으면 "")
const areaSql = (a) => [...a.tables, ...(a.functions || [])].filter((x) => x.sql)
  .map((x) => "-- ===== " + x.schema + "." + x.name + " =====\n" + x.sql.replace(/\s+$/, "") + "\n").join("\n");
function viewCore(r) {
  const areas = state.data.core.areas;
  const all = areas.flatMap((a) => a.tables);
  const files = state.data.core.files || [];
  const isSql = r.slug === "sql" && files.length > 0;
  const tabs = h("div", { class: "tabs", role: "group", "aria-label": "보기" },
    h("button", { type: "button", "aria-pressed": String(!isSql), onclick: () => go("#core") }, "영역", h("span", { class: "count muted" }, areas.length)),
    files.length ? h("button", { type: "button", "aria-pressed": String(isSql), onclick: () => go("#core/sql") }, "SQL 카드", h("span", { class: "count muted" }, files.length)) : null);
  const doc = state.data.core.doc || {};
  const docFiles = doc.files || {};
  const head = [docHead(doc, "공용 모듈 nomad_core", null, "영역별 카드 · 테이블 " + all.length + "개 · migrations " + files.length + "개"),
    diagramSection(doc, { title: "표 관계 ERD · nomad_core · 표 " + all.length, tables: all })];
  if (isSql) {
    state.redraw = () => {};
    // 전체: 파일명 순(=적용 순서)으로 이어 붙인 원문
    const joined = files.map((f) => "-- ===== " + baseName(f.path) + " =====\n" + f.sql.replace(/\s+$/, "") + "\n").join("\n");
    const fileItems = [{ title: "nomad_core_all.sql", sub: "전체 · 적용 순서대로 합침", desc: "migrations " + files.length + "개를 파일명 순으로 이어 붙인 원문", sql: joined, filename: "nomad_core_all.sql" },
      ...files.map((f) => ({ title: baseName(f.path), sub: f.path.replace(/\/[^/]*$/, ""), desc: sqlSummary(f.sql), doc: docFiles[f.path], sql: f.sql, filename: baseName(f.path) }))];
    const areaItems = areas.map((a, i) => {
      const sql = areaSql(a);
      return sql ? { title: a.name, sub: "영역 · 테이블 " + a.tables.length + " · 함수 " + (a.functions || []).length, sql, filename: "nomad_core_area_" + (i + 1) + ".sql" } : null;
    }).filter(Boolean);
    return [head, tabs, h("div", {}, sqlCards([{ name: "migrations 파일", items: fileItems, mono: true }, { name: "영역별 SQL", items: areaItems }]))];
  }
  const draw = () => {
    host.replaceChildren(h("div", { class: "cards" }, areas.map((a) => {
      const ts = a.tables.filter(matches);
      if (!ts.length && (state.q || Object.values(state.filters).some(Boolean))) return null;
      const sql = areaSql(a);
      const paneId = "area-sql-" + (areas.indexOf(a) + 1);
      const pane = h("div", { class: "card__sql", id: paneId, hidden: true });
      const sqlBtn = sql ? h("button", { type: "button", class: "btn card__sqlbtn", "aria-expanded": "false", "aria-controls": paneId }, "SQL 보기") : null;
      if (sqlBtn) sqlBtn.addEventListener("click", () => {
        const on = pane.hidden;
        pane.hidden = !on; sqlBtn.setAttribute("aria-expanded", String(on)); sqlBtn.textContent = on ? "SQL 닫기" : "SQL 보기";
        if (on && !pane.firstChild) pane.append(sqlViewer("nomad_core · " + a.name, sql, "nomad_core_area_" + (areas.indexOf(a) + 1) + ".sql"));
      });
      return h("section", { class: "card" },
        h("h3", {}, a.name, badge(a.tables.length + " 테이블"), badge((a.functions || []).length + " 함수"), sqlBtn),
        pane,
        rowList(ts),
        (a.functions || []).length ? [h("h4", {}, "함수 (" + a.functions.length + ")"), h("div", { class: "rows" }, a.functions.map(fnRow))] : null);
    })));
  };
  const host = h("div", {});
  state.redraw = draw; draw();
  return [head, tabs, filterBar(all, draw), host];
}

// 제품 SQL 카드: 구조별 묶음(맨 앞 = 그 구조 합본) + 앱 공통(app) + 번들(구조별 전체 SQL, 열 때 불러옴)
const STRUCT_GROUPS = [["existing", "기존 (원본)"], ["single", "단일 (user)"], ["tenant", "테넌트 (org)"], ["app", "앱 공통 (app)"], ["monorepo", "모노레포"], ["isolated", "격리형 (isolated)"]];
function productSqlCards(p) {
  const isApp = (f) => f.path.includes("/" + p.slug + "/app/");
  const seen = new Set();
  const byGroup = (k) => p.files.filter((f) => {
    const g = isApp(f) ? "app" : f.structure;
    if (g !== k || seen.has(f.path)) return false;
    seen.add(f.path); return true;
  });
  const docFiles = (p.doc && p.doc.files) || {};
  const fileItem = (f) => ({ title: baseName(f.path), sub: f.path.replace(/\/[^/]*$/, "") + (f.src && f.src !== f.path ? " · 원본 " + f.src : ""),
    desc: sqlSummary(f.sql), doc: docFiles[f.src || f.path], sql: f.sql, filename: baseName(f.path) });
  const groups = STRUCT_GROUPS.map(([k, label]) => {
    const list = byGroup(k);
    const items = list.map(fileItem);
    if (list.length > 1) {
      const fn = p.slug + "_" + k + "_all.sql";
      items.unshift({ title: fn, sub: label + " · 적용 순서대로 합침", desc: "이 묶음 " + list.length + "개 파일을 순서대로 이어 붙인 원문",
        sql: list.map((f) => "-- ===== " + baseName(f.path) + " =====\n" + f.sql.replace(/\s+$/, "") + "\n").join("\n"), filename: fn });
    }
    return { name: label, mono: true, items };
  });
  const names = Object.fromEntries(VARIANTS);
  const inMono = p.files.some((f) => f.structure === "monorepo"); // 모노레포 번들은 이 제품이 들어 있을 때만
  const bundles = (state.data.bundles || []).filter((b) => b.slug === p.slug || (b.structure === "monorepo" && inMono));
  groups.push({ name: "번들 (구조별 전체 SQL)", mono: true, items: bundles.map((b) => ({
    title: baseName(b.file), sub: (names[b.structure] || b.structure) + " 설치용 전체" + (b.slug ? "" : " · 번들된 제품 전부"), desc: "core + 제품 migrations " + b.files + "개를 합친 설치용 원문(열 때 불러옴)",
    src: b.file, filename: baseName(b.file), badges: [b.files + "파일", Math.round(b.bytes / 1024) + " KiB"] })) });
  return sqlCards(groups);
}

function viewProduct(r) {
  const p = state.data.products.find((x) => x.slug === r.slug);
  if (!p) return h("div", { class: "notice" }, "알 수 없는 제품: " + r.slug);
  const tab = VARIANTS.some(([k]) => k === r.tab) ? r.tab : "existing";
  const isSql = r.tab === "sql" && (p.files || []).length > 0;
  const tabs = h("div", { class: "tabs", role: "group", "aria-label": "구조" }, VARIANTS.map(([k, label]) => {
    const n = k === "local" ? p.local_storage.length : (p.variants[k] || { tables: [] }).tables.length;
    return h("button", { type: "button", "aria-pressed": String(!isSql && k === tab), onclick: () => go("#product/" + p.slug + "/" + k) }, label, h("span", { class: "count muted" }, n));
  }), (p.files || []).length ? h("button", { type: "button", "aria-pressed": String(isSql), onclick: () => go("#product/" + p.slug + "/sql") }, "SQL 카드", h("span", { class: "count muted" }, p.files.length)) : null);
  const host = h("div", {});
  let tables = [];
  if (isSql) {
    state.redraw = () => {};
    host.append(productSqlCards(p));
  } else if (tab === "local") {
    state.redraw = () => {};
    host.append(localTable(p));
  } else {
    tables = (p.variants[tab] || { tables: [] }).tables;
    const draw = () => host.replaceChildren(rowList(tables.filter(matches), true));
    state.redraw = draw; draw();
    if (!tables.length) host.replaceChildren(h("div", { class: "empty" }, "이 구조는 아직 정리되지 않았습니다."));
  }
  // ERD 구조: 지금 탭(표가 있으면), 아니면 테넌트→단일→격리형→모노레포→기존 중 처음으로 표가 있는 구조
  const vt = (k) => (p.variants[k] || { tables: [] }).tables;
  const erdKey = !isSql && vt(tab).length ? tab : ["tenant", "single", "isolated", "monorepo", "existing"].find((k) => vt(k).length);
  const vname = Object.fromEntries(VARIANTS);
  return [
    docHead(p.doc, p.name, [badge(p.form === "isolated" ? "격리형" : p.form === "org" ? "org형" : "user형", "accent"), (p.clients || []).map((c) => badge(CLIENTS[c] || c)), p.placeholder ? badge("자리표시", "warn") : null],
      "레포 " + p.repo + " · " + p.note),
    diagramSection(p.doc, erdKey ? { title: "표 관계 ERD · " + vname[erdKey] + " · 표 " + vt(erdKey).length, tables: vt(erdKey) } : null),
    tabs, isSql || tab === "local" ? null : filterBar(tables, () => state.redraw()), host];
}

function localTable(p) {
  if (!p.local_storage.length) return h("div", { class: "empty" }, "로컬 저장소 키가 아직 정리되지 않았습니다.");
  return h("div", { class: "scroll", role: "region", "aria-label": "로컬 저장소 키", tabindex: "0" }, h("table", {},
    h("thead", {}, h("tr", {}, ["키", "플랫폼", "내용", "동기화", "비밀", "로그아웃 시"].map((x) => h("th", { scope: "col" }, x)))),
    h("tbody", {}, p.local_storage.map((k) => h("tr", {},
      h("td", { class: "mono" }, k.key), h("td", {}, k.platform), h("td", {}, k.content), h("td", {}, k.sync),
      h("td", {}, k.secret ? badge("비밀 — 저장 금지", "danger") : badge("아님", "ok")),
      h("td", {}, k.clear_on_logout ? "삭제" : "유지"))))));
}

function viewCompare() {
  const cell = (p, k) => {
    const ts = (p.variants[k] || { tables: [] }).tables;
    const core = ts.filter((t) => (t.columns || []).some((c) => (c.fk || "").startsWith("nomad_core."))).length;
    return h("td", { class: "num" }, ts.length ? [String(ts.length), h("span", { class: "muted" }, " (코어 참조 " + core + ")")] : h("span", { class: "muted" }, "-"));
  };
  return [h("div", { class: "page-head" }, h("h2", {}, "제품 × 구조 비교"), h("p", {}, "칸 = 테이블 수 (코어 참조: nomad_core를 FK로 가리키는 테이블 수)")),
    h("div", { class: "scroll", role: "region", "aria-label": "제품 구조 비교표", tabindex: "0" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "제품"), VARIANTS.slice(0, 5).map(([, l]) => h("th", { scope: "col", class: "num" }, l)), h("th", { scope: "col", class: "num" }, "로컬 키"))),
      h("tbody", {}, state.data.products.map((p) => h("tr", {},
        h("th", { scope: "row" }, p.name, p.placeholder ? [" ", badge("자리표시", "warn")] : null),
        VARIANTS.slice(0, 5).map(([k]) => cell(p, k)), h("td", { class: "num" }, String(p.local_storage.length)))))))];
}

/* ---------- 렌더 ---------- */
function render() {
  if (!state.data) return;
  const r = route();
  renderNav(r);
  const view = r.type === "product" ? viewProduct(r) : r.type === "category" ? viewCategory(r) : r.type === "compare" ? viewCompare() : viewCore(r);
  $main.replaceChildren(...[view].flat(Infinity).filter(Boolean));
  const sel = $main.querySelector('.tabs [aria-pressed="true"]'); // 좁은 화면에서 가로 스크롤 밖의 현재 탭을 보이게
  if (sel) sel.scrollIntoView({ block: "nearest", inline: "nearest" });
}
function showError(err) {
  $main.replaceChildren(h("div", { class: "notice", role: "alert" },
    h("strong", {}, "데이터를 불러오지 못했습니다. "), "(" + err.message + ")",
    h("p", { class: "muted" }, "파일을 직접 열면(file://) 브라우저가 fetch를 막습니다. 이 폴더에서 `python -m http.server 8080`을 실행하고 http://127.0.0.1:8080/ 로 여세요.")));
}

document.getElementById("q").addEventListener("input", (e) => { state.q = e.target.value.trim(); if (state.redraw) state.redraw(); });
window.addEventListener("hashchange", () => { state.filters = { schema: "", owner: "", noRls: false, client: "" }; render(); $main.focus(); });

const dataParam = new URLSearchParams(location.search).get("data");
const okParam = dataParam && /^[\w./-]+\.json$/.test(dataParam) && !dataParam.startsWith("/");
const fetchJson = (src) => fetch(src).then((res) => { if (!res.ok) throw new Error("HTTP " + res.status + " " + src); return res.json(); });
(okParam ? fetchJson(dataParam) : fetchJson("data/schema.json").catch(() => fetchJson("sample-data.json")))
  .then((d) => { state.data = d; render(); }).catch(showError);
