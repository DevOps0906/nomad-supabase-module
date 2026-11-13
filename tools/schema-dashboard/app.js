"use strict";
// 정적 대시보드. 데이터: sample-data.json(기본) — ?data=<경로> 로 다른 JSON 지정. 사용자 데이터는 textContent로만 넣는다.
const VARIANTS = [["existing", "기존"], ["single", "단일"], ["tenant", "테넌트"], ["monorepo", "모노레포"], ["local", "로컬 저장소"]];
const OWNERS = { user: "user", org: "org", public: "공개", server: "서버", indirect: "간접" };
const CLIENTS = { web: "웹", app: "앱", desktop: "데스크톱", worker: "워커" };
const THEME_KEY = "nomad.theme";

const state = { data: null, filters: { schema: "", owner: "", noRls: false, client: "" }, q: "" };
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

/* ---------- 테마 ---------- */
function currentTheme() { try { return localStorage.getItem(THEME_KEY) || "system"; } catch (e) { return "system"; } }
function applyTheme(t) {
  const root = document.documentElement;
  if (t === "light" || t === "dark") root.setAttribute("data-theme", t); else root.removeAttribute("data-theme");
  try { if (t === "system") localStorage.removeItem(THEME_KEY); else localStorage.setItem(THEME_KEY, t); } catch (e) { /* 저장 불가여도 즉시 적용은 유지 */ }
  document.querySelectorAll("[data-theme-set]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.themeSet === t)));
}
document.querySelectorAll("[data-theme-set]").forEach((b) => b.addEventListener("click", () => applyTheme(b.dataset.themeSet)));
// 초기 표시: theme-init.js가 이미 적용한 상태를 버튼에 반영만 한다(?theme=는 저장하지 않는 임시 지정)
const shown = document.documentElement.getAttribute("data-theme") || "system";
document.querySelectorAll("[data-theme-set]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.themeSet === shown)));

/* ---------- 라우팅: #core · #product/<slug>/<tab> · #compare ---------- */
function route() {
  const p = (location.hash || "#core").slice(1).split("/");
  return { type: p[0] || "core", slug: p[1], tab: p[2] || "existing" };
}
function go(hash) { location.hash = hash; }

function renderNav(r) {
  $nav.replaceChildren();
  const item = (label, hash, on) => $nav.append(h("button", { type: "button", "aria-current": on ? "page" : false, onclick: () => go(hash) }, label));
  $nav.append(h("span", { class: "nav__label" }, "공용 모듈"));
  item("nomad_core", "#core", r.type === "core");
  $nav.append(h("span", { class: "nav__label" }, "제품"));
  for (const p of state.data.products) item(p.name, "#product/" + p.slug + "/existing", r.type === "product" && r.slug === p.slug);
  $nav.append(h("span", { class: "nav__label" }, "비교"));
  item("제품 × 구조", "#compare", r.type === "compare");
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
  const body = h("div", { class: "row__body" },
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
  return h("details", { class: "row" },
    h("summary", {},
      h("span", { class: "row__name" }, h("span", { class: "mono" }, t.name), h("small", {}, t.schema)),
      h("span", { class: "row__meta" }, meta),
      t.renamed_from ? h("span", { class: "row__rename" }, "기존 → 새: ", h("span", { class: "mono" }, t.renamed_from + " → " + t.schema + "." + t.name)) : null),
    body);
}
const rowList = (tables, openFirst) => tables.length ? h("div", { class: "rows" }, tables.map((t, i) => { const el = tableRow(t); if (openFirst && i === 0) el.open = true; return el; })) : h("div", { class: "empty" }, "조건에 맞는 테이블이 없습니다.");

/* ---------- 화면 ---------- */
function viewCore() {
  const areas = state.data.core.areas;
  const all = areas.flatMap((a) => a.tables);
  const draw = () => {
    host.replaceChildren(h("div", { class: "cards" }, areas.map((a) => {
      const ts = a.tables.filter(matches);
      if (!ts.length && (state.q || Object.values(state.filters).some(Boolean))) return null;
      return h("section", { class: "card" },
        h("h3", {}, a.name, badge(a.tables.length + " 테이블"), badge((a.functions || []).length + " 함수")),
        rowList(ts),
        (a.functions || []).length ? [h("h4", {}, "함수"), h("div", { class: "fnlist" }, a.functions.map((f) =>
          h("span", { class: "badge", title: f.grants.join(", ") }, h("span", { class: "mono" }, f.name), f.security_definer ? " · definer" : "", " · " + f.grants.join("/"))))] : null);
    })));
  };
  const host = h("div");
  state.redraw = draw; draw();
  return [h("div", { class: "page-head" }, h("h2", {}, "공용 모듈 nomad_core"), h("p", {}, "영역별 카드 · 테이블 " + all.length + "개")), filterBar(all, draw), host];
}

function viewProduct(r) {
  const p = state.data.products.find((x) => x.slug === r.slug);
  if (!p) return h("div", { class: "notice" }, "알 수 없는 제품: " + r.slug);
  const tab = VARIANTS.some(([k]) => k === r.tab) ? r.tab : "existing";
  const tabs = h("div", { class: "tabs", role: "tablist", "aria-label": "구조" }, VARIANTS.map(([k, label]) => {
    const n = k === "local" ? p.local_storage.length : (p.variants[k] || { tables: [] }).tables.length;
    return h("button", { type: "button", role: "tab", "aria-selected": String(k === tab), onclick: () => go("#product/" + p.slug + "/" + k) }, label, h("span", { class: "count muted" }, n));
  }));
  const host = h("div", { role: "tabpanel" });
  let tables = [];
  if (tab === "local") {
    state.redraw = () => {};
    host.append(localTable(p));
  } else {
    tables = (p.variants[tab] || { tables: [] }).tables;
    const draw = () => host.replaceChildren(rowList(tables.filter(matches), true));
    state.redraw = draw; draw();
    if (!tables.length) host.replaceChildren(h("div", { class: "empty" }, "이 구조는 아직 정리되지 않았습니다."));
  }
  return [
    h("div", { class: "page-head" }, h("h2", {}, p.name), badge(p.form === "org" ? "org형" : "user형", "accent"), (p.clients || []).map((c) => badge(CLIENTS[c] || c)), p.placeholder ? badge("자리표시", "warn") : null, h("p", {}, "레포 " + p.repo + " · " + p.note)),
    tabs, tab === "local" ? null : filterBar(tables, () => state.redraw()), host];
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
      h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "제품"), VARIANTS.slice(0, 4).map(([, l]) => h("th", { scope: "col", class: "num" }, l)), h("th", { scope: "col", class: "num" }, "로컬 키"))),
      h("tbody", {}, state.data.products.map((p) => h("tr", {},
        h("th", { scope: "row" }, p.name, p.placeholder ? [" ", badge("자리표시", "warn")] : null),
        VARIANTS.slice(0, 4).map(([k]) => cell(p, k)), h("td", { class: "num" }, String(p.local_storage.length)))))))];
}

/* ---------- 렌더 ---------- */
function render() {
  if (!state.data) return;
  const r = route();
  renderNav(r);
  const view = r.type === "product" ? viewProduct(r) : r.type === "compare" ? viewCompare() : viewCore();
  $main.replaceChildren(...[view].flat());
}
function showError(err) {
  $main.replaceChildren(h("div", { class: "notice", role: "alert" },
    h("strong", {}, "데이터를 불러오지 못했습니다. "), "(" + err.message + ")",
    h("p", { class: "muted" }, "파일을 직접 열면(file://) 브라우저가 fetch를 막습니다. 이 폴더에서 `python -m http.server 8080`을 실행하고 http://127.0.0.1:8080/ 로 여세요.")));
}

document.getElementById("q").addEventListener("input", (e) => { state.q = e.target.value.trim(); if (state.redraw) state.redraw(); });
window.addEventListener("hashchange", () => { state.filters = { schema: "", owner: "", noRls: false, client: "" }; render(); $main.focus(); });

const dataParam = new URLSearchParams(location.search).get("data");
const src = dataParam && /^[\w./-]+\.json$/.test(dataParam) && !dataParam.startsWith("/") ? dataParam : "sample-data.json";
fetch(src).then((res) => { if (!res.ok) throw new Error("HTTP " + res.status + " " + src); return res.json(); })
  .then((d) => { state.data = d; render(); }).catch(showError);
