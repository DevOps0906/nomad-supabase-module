#!/usr/bin/env python3
"""스키마 대시보드 데이터 생성기 (표준 라이브러리만).

core(supabase/migrations/*nomad_core*.sql) · products/<slug>/{user,org,app}/*.sql · 각 레포 기존 migrations ·
bundles/ 를 읽어 tools/schema-dashboard/data/schema.json 과 data/bundles/*.sql 을 만든다. 읽기만 한다(원본 수정 없음).
실행: python scripts/schema-dashboard.py [--out <schema.json>]
레포 위치: 기본 D:\\WorkSpace\\DEV (환경 변수 NOMAD_DEV_ROOT로 변경). 비밀 패턴이 출력에 있으면 실패한다.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEV = Path(os.environ.get("NOMAD_DEV_ROOT", r"D:\WorkSpace\DEV"))
OUT = ROOT / "tools" / "schema-dashboard" / "data" / "schema.json"
if "--out" in sys.argv:
    OUT = Path(sys.argv[sys.argv.index("--out") + 1])

KNOWN = [  # slug, 이름, 레포, 형태, 사용처 — 레포 기존 migrations가 있는 제품. 그 밖의 products/<slug>/는 discover_products()가 찾는다
    ("humscore", "HumScore", "humscore", "user", ["web", "app", "desktop", "worker"]),
    ("lottolab", "LOTTO-LAB", "LOTTO-LAB", "user", ["app", "desktop", "web", "worker"]),
    ("contentflow", "ContentFlow", "ContentFlow-AI-V2.0", "org", ["web", "worker"]),
    ("knowflow", "KnowFlow", "KNOWFLOW-AI", "org", ["web", "worker"]),
    ("shorts", "Shorts", "Shopping-Shorts-Maker", "org", ["web", "worker"]),
]

CORE_AREAS = [
    ("계정·조직", ["profiles", "organizations", "memberships", "invitations", "platform_admins"], r"profile|org|member|invit|admin|account|touch|role"),
    ("플랜·기능·한도", ["products", "plans", "features", "plan_features", "plan_limits"], r"plan|feature|limit|entitle"),
    ("구독·이용권·크레딧", ["subscriptions", "addon_products", "addon_purchases", "feature_grants", "credit_ledger"], r"subscri|addon|credit|grant|purchase"),
    ("인증·소셜 로그인", ["oauth_states", "api_providers"], r"oauth|social|provider|auth"),
    ("API 키", ["provider_credentials"], r"credential|api_key|secret|vault"),
]

SECRET_RE = re.compile(r"sk-[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{20,}|service_role[_ ]?key\s*[:=]\s*['\"]?[A-Za-z0-9._-]{20,}", re.I)


def find_secret(text):
    """비밀 키 패턴의 첫 일치 문자열, 없으면 None."""
    m = SECRET_RE.search(text)
    return m.group(0) if m else None


# ---------- SQL 분해 ----------
def blank_comments(sql):
    """주석을 같은 길이의 공백으로 바꾼 사본(문자열·달러 인용은 유지)."""
    out, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in sql[i:j])); i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2; continue
                    break
                j += 1
            out.append(sql[i:j + 1]); i = j + 1
        elif c == "$":
            m = re.match(r"\$([A-Za-z_]\w*)?\$", sql[i:])
            if m:
                tag = m.group(0)
                j = sql.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                out.append(sql[i:j]); i = j
            else:
                out.append(c); i += 1
        else:
            out.append(c); i += 1
    return "".join(out)


def split_statements(sql):
    """[(원문, 분석용 사본)] — 최상위 ; 로 나눈다(원문은 앞선 주석 포함)."""
    clean = blank_comments(sql)
    res, start, i, n = [], 0, 0, len(clean)
    while i < n:
        c = clean[i]
        if c == "'":
            j = i + 1
            while j < n:
                if clean[j] == "'":
                    if j + 1 < n and clean[j + 1] == "'":
                        j += 2; continue
                    break
                j += 1
            i = j + 1
        elif c == "$":
            m = re.match(r"\$([A-Za-z_]\w*)?\$", clean[i:])
            if m:
                tag = m.group(0)
                j = clean.find(tag, i + len(tag))
                i = n if j < 0 else j + len(tag)
            else:
                i += 1
        elif c == ";":
            raw, cl = sql[start:i + 1], clean[start:i + 1]
            if cl.strip(" \n\r\t;"):
                res.append((raw.strip("\n\r"), cl.strip()))
            start = i + 1; i += 1
        else:
            i += 1
    raw, cl = sql[start:], clean[start:]
    if cl.strip():
        res.append((raw.strip("\n\r"), cl.strip()))
    return res


def split_top(text, sep=","):
    parts, depth, cur, i, n = [], 0, [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = i + 1
            while j < n and not (text[j] == "'" and text[j + 1:j + 2] != "'"):
                j += 2 if text[j] == "'" else 1
            cur.append(text[i:j + 1]); i = j + 1; continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == sep and depth == 0:
            parts.append("".join(cur).strip()); cur = []
        else:
            cur.append(c)
        i += 1
    if "".join(cur).strip():
        parts.append("".join(cur).strip())
    return parts


def match_paren(text, open_idx):
    depth, i, n = 0, open_idx, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            i += 1
            while i < n and not (text[i] == "'" and text[i + 1:i + 2] != "'"):
                i += 2 if text[i] == "'" else 1
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


IDENT = r'(?:"[^"]+"|[A-Za-z_]\w*)'
QNAME = rf"{IDENT}(?:\s*\.\s*{IDENT})?"


def qname(s, default="public"):
    parts = [p.strip().strip('"') for p in re.split(r"\.", s.strip(), maxsplit=1)]
    return (parts[0], parts[1]) if len(parts) == 2 else (default, parts[0])


# ---------- 컬럼 ----------
COL_STOP = re.compile(r"\b(not\s+null|null|default|primary\s+key|references|check|unique|generated|constraint|collate)\b", re.I)
REF_RE = re.compile(rf"references\s+({QNAME})\s*(?:\(\s*({IDENT})\s*\))?", re.I)


def fk_text(m):
    s, t = qname(m.group(1))
    return f"{s}.{t}.{(m.group(2) or 'id').strip(chr(34))}"


def parse_column(item):
    m = re.match(rf"({IDENT})\s+(.*)$", item, re.S)
    if not m:
        return None
    name, rest = m.group(1).strip('"'), m.group(2)
    st = COL_STOP.search(rest)
    typ = re.sub(r"\s+", " ", (rest[:st.start()] if st else rest).strip())
    pk = bool(re.search(r"primary\s+key", rest, re.I))
    nn = bool(re.search(r"not\s+null", rest, re.I)) or pk
    ref = REF_RE.search(rest)
    return {"name": name, "type": typ, "nullable": not nn, "pk": pk, "fk": fk_text(ref) if ref else None}


def apply_constraint(cols, item):
    """table-level primary key / foreign key."""
    by = {c["name"]: c for c in cols}
    m = re.search(r"primary\s+key\s*\(([^)]*)\)", item, re.I)
    if m:
        for n in (x.strip().strip('"') for x in m.group(1).split(",")):
            if n in by:
                by[n]["pk"] = True; by[n]["nullable"] = False
    m = re.search(rf"foreign\s+key\s*\(([^)]*)\)\s*{REF_RE.pattern}", item, re.I)
    if m:
        local = [x.strip().strip('"') for x in m.group(1).split(",")]
        s, t = qname(m.group(2))
        tgt = (m.group(3) or "id").strip('"').split(",")[0]
        if len(local) >= 1 and local[0] in by:
            by[local[0]]["fk"] = f"{s}.{t}.{tgt}"


# ---------- 상태 누적 ----------
class Schema:
    def __init__(self):
        self.tables = {}   # (schema,name) -> dict
        self.funcs = {}    # (schema,name,args) -> dict
        self.order = 0

    def table_of(self, qn, default="public"):
        return self.tables.get(qname(qn, default))

    def attach(self, qn, raw):
        t = self.table_of(qn)
        if t is not None:
            t["_stmts"].append(raw)

    def feed(self, path, sql):
        for raw, cl in split_statements(sql):
            try:
                self.statement(path, raw, cl)
            except Exception as e:  # 파싱 실패는 해당 문장만 건너뛴다
                print(f"  경고: {path}: {e}: {cl[:60]!r}", file=sys.stderr)

    def statement(self, path, raw, cl):
        low = re.sub(r"\s+", " ", cl.lower())
        if low.startswith("do ") and "enable row level security" in low:  # 일괄 RLS 루프: schemaname in ('a','b')
            mm = re.search(r"schemaname\s+in\s*\(([^)]*)\)", cl, re.I)
            if mm:
                schemas = set(re.findall(r"'([^']+)'", mm.group(1)))
                for t in self.tables.values():
                    if t["schema"] in schemas:
                        t["rls"] = True
                        t["_stmts"].append("-- (일괄 RLS 켜기 루프 — do 블록은 파일 원문 참조)")
            return
        m = re.match(rf"create (?:unlogged )?table (?:if not exists )?({QNAME})\s*\(", cl, re.I)
        if m:
            key = qname(m.group(1))
            op = cl.index("(", m.end() - 1)
            body = cl[op + 1:match_paren(cl, op)]
            cols = []
            for item in split_top(body):
                if re.match(r"(constraint|primary\s+key|foreign\s+key|unique|check|exclude|like)\b", item, re.I):
                    apply_constraint(cols, item)
                else:
                    c = parse_column(item)
                    if c:
                        cols.append(c)
            self.tables[key] = {"schema": key[0], "name": key[1], "comment": None, "columns": cols, "rls": False, "policies": [],
                                "source_file": path, "_stmts": [raw]}
            return
        m = re.match(rf"drop table (?:if exists )?(.+?)(?: cascade| restrict)?$", cl, re.I | re.S)
        if m:
            for part in split_top(m.group(1)):
                self.tables.pop(qname(part), None)
            return
        m = re.match(rf"alter table (?:only )?(?:if exists )?({QNAME})\s+(.*)$", cl, re.I | re.S)
        if m:
            self.alter_table(m, raw)
            return
        m = re.match(rf"create (?:unique )?index (?:concurrently )?(?:if not exists )?{IDENT}?\s*on (?:only )?({QNAME})", cl, re.I)
        if m:
            self.attach(m.group(1), raw); return
        m = re.match(rf"create trigger .*? on ({QNAME})", cl, re.I | re.S)
        if m:
            self.attach(m.group(1), raw); return
        m = re.match(rf"create policy ({IDENT}) on ({QNAME})(.*)$", cl, re.I | re.S)
        if m:
            t = self.table_of(m.group(2))
            if t is not None:
                rest = m.group(3)
                cmd = re.search(r"\bfor\s+(all|select|insert|update|delete)\b", rest, re.I)
                roles = re.search(r"\bto\s+(.+?)(?=\s+(?:using|with\s+check)\b|$)", rest, re.I | re.S)
                t["policies"].append({"name": m.group(1).strip('"'), "cmd": (cmd.group(1).upper() if cmd else "ALL"),
                                      "roles": [r.strip() for r in roles.group(1).split(",")] if roles else ["public"]})
                t["_stmts"].append(raw)
            return
        m = re.match(rf"drop policy (?:if exists )?({IDENT}) on ({QNAME})", cl, re.I)
        if m:
            t = self.table_of(m.group(2))
            if t is not None:
                t["policies"] = [p for p in t["policies"] if p["name"] != m.group(1).strip('"')]
            return
        m = re.match(r"(grant|revoke)\b.*?\bon (?:table )?(?!all |function|sequence|schema|type|domain)(.+?)\s+(?:to|from)\s", cl, re.I | re.S)
        if m:
            for part in split_top(m.group(2)):
                self.attach(part.strip(), raw)
            return
        m = re.match(rf"comment on table ({QNAME}) is\s+'((?:[^']|'')*)'", cl, re.I | re.S)
        if m:
            t = self.table_of(m.group(1))
            if t is not None:
                t["comment"] = m.group(2).replace("''", "'"); t["_stmts"].append(raw)
            return
        m = re.match(rf"comment on column ({IDENT}\s*\.\s*{IDENT}(?:\s*\.\s*{IDENT})?)", cl, re.I)
        if m:
            parts = [p.strip().strip('"') for p in m.group(1).split(".")]
            self.attach(".".join(parts[:-1]), raw); return
        m = re.match(rf"create (?:or replace )?function ({QNAME})\s*\(", cl, re.I)
        if m:
            key = qname(m.group(1))
            op = cl.index("(", m.end() - 1)
            args = re.sub(r"\s+", " ", cl[op + 1:match_paren(cl, op)]).lower()
            args = ",".join(re.sub(r"\s+default\s+.*$", "", a.strip()) for a in split_top(args))
            self.funcs[(key[0], key[1], args)] = {"schema": key[0], "name": key[1],
                                                  "security_definer": bool(re.search(r"security\s+definer", cl, re.I)),
                                                  "grants": [], "source_file": path, "_stmts": [raw]}
            return
        m = re.match(rf"drop function (?:if exists )?({QNAME})", cl, re.I)
        if m:
            k = qname(m.group(1))
            for fk in [x for x in self.funcs if x[0] == k[0] and x[1] == k[1]]:
                self.funcs.pop(fk)
            return
        m = re.match(rf"(grant|revoke)\s+execute\s+on\s+function\s+({QNAME})\s*(\(.*?\))?\s+(to|from)\s+(.+)$", cl, re.I | re.S)
        if m:
            k = qname(m.group(2))
            roles = [r.strip().lower() for r in re.split(r",", re.sub(r"\s+with\s+grant\s+option.*$", "", m.group(5), flags=re.I)) if r.strip()]
            for fk, f in self.funcs.items():
                if fk[0] == k[0] and fk[1] == k[1]:
                    f["_stmts"].append(raw)
                    for r in roles:
                        if m.group(1).lower() == "grant" and r not in f["grants"]:
                            f["grants"].append(r)
                        if m.group(1).lower() == "revoke" and r in f["grants"]:
                            f["grants"].remove(r)

    def alter_table(self, m, raw):
        qn, rest = m.group(1), m.group(2)
        t = self.table_of(qn)
        if t is None:
            return
        t["_stmts"].append(raw)
        low = re.sub(r"\s+", " ", rest.strip()).lower()
        mm = re.match(rf"rename to ({IDENT})", rest, re.I)
        if mm:
            self.tables.pop((t["schema"], t["name"]), None)
            t["name"] = mm.group(1).strip('"')
            self.tables[(t["schema"], t["name"])] = t
            return
        mm = re.match(rf"rename (?:column )?({IDENT}) to ({IDENT})", rest, re.I)
        if mm and not low.startswith("rename constraint"):
            for c in t["columns"]:
                if c["name"] == mm.group(1).strip('"'):
                    c["name"] = mm.group(2).strip('"')
            return
        mm = re.match(rf"set schema ({IDENT})", rest, re.I)
        if mm:
            self.tables.pop((t["schema"], t["name"]), None)
            t["schema"] = mm.group(1).strip('"')
            self.tables[(t["schema"], t["name"])] = t
            return
        for act in split_top(rest):
            a = re.sub(r"\s+", " ", act.strip())
            al = a.lower()
            if re.match(r"(enable|force) row level security", al):
                t["rls"] = True
            elif re.match(r"disable row level security", al):
                t["rls"] = False
            elif re.match(r"add column ", al):
                c = parse_column(re.sub(r"^add column (?:if not exists )?", "", act.strip(), flags=re.I))
                if c and not any(x["name"] == c["name"] for x in t["columns"]):
                    t["columns"].append(c)
            elif re.match(r"drop column ", al):
                n = re.match(rf"drop column (?:if exists )?({IDENT})", a, re.I).group(1).strip('"')
                t["columns"] = [c for c in t["columns"] if c["name"] != n]
            elif re.match(r"add (?:constraint \S+ )?(primary key|foreign key)", al):
                apply_constraint(t["columns"], act)
            elif re.match(r"add (?!column|constraint|primary|foreign|unique|check|exclude)", al):
                c = parse_column(re.sub(r"^add\s+", "", act.strip(), flags=re.I))
                if c and not any(x["name"] == c["name"] for x in t["columns"]):
                    t["columns"].append(c)
            else:
                mm = re.match(rf"alter column ({IDENT}) (?:set data )?type (.+?)(?: using .*)?$", a, re.I)
                if mm:
                    for c in t["columns"]:
                        if c["name"] == mm.group(1).strip('"'):
                            c["type"] = mm.group(2).strip()
                mm = re.match(rf"alter column ({IDENT}) (set|drop) not null", a, re.I)
                if mm:
                    for c in t["columns"]:
                        if c["name"] == mm.group(1).strip('"'):
                            c["nullable"] = mm.group(2).lower() == "drop"


# ---------- 분류 ----------
def finish_tables(sch, repo_note=None, renames=None):
    """내부 dict -> 출력 T. owner·sync 판정."""
    tabs = list(sch.tables.values())
    for t in tabs:
        names = {c["name"] for c in t["columns"]}
        roles = {r.lower() for p in t["policies"] for r in p["roles"]}
        if "organization_id" in names or any((c["fk"] or "") == "nomad_core.organizations.id" for c in t["columns"]):
            owner = "org"
        elif any(n in names for n in ("user_id", "owner_id", "created_by", "profile_id")) or any((c["fk"] or "") in ("auth.users.id", "nomad_core.profiles.id") for c in t["columns"]):
            owner = "user"
        else:
            owner = None
        t["owner"] = owner
        t["_roles"] = roles
    for t in tabs:  # 소유 미정: 정책이 없거나 service_role뿐이면 서버, anon 허용이면 공개, 소유 테이블을 FK로 가리키면 간접
        if t["owner"]:
            continue
        refs = [sch.tables.get(qname(c["fk"].rsplit(".", 1)[0])) for c in t["columns"] if c["fk"]]
        if any(r and r["owner"] in ("user", "org") for r in refs):
            t["owner"] = "indirect"
        elif "anon" in t["_roles"] or "public" in t["_roles"]:
            t["owner"] = "public"
        elif not t["policies"] or t["_roles"] <= {"service_role"}:
            t["owner"] = "server"
        else:
            t["owner"] = "public"
    out = []
    for t in tabs:
        names = {c["name"] for c in t["columns"]}
        key = (t["schema"], t["name"])
        out.append({"schema": t["schema"], "name": t["name"], "comment": t["comment"], "owner": t["owner"], "rls": t["rls"],
                    "policies": t["policies"], "columns": t["columns"], "used_by": [],
                    "sync": {"updated_at", "deleted_at"} <= names,
                    "source_file": t["source_file"], "renamed_from": (renames or {}).get(t["name"]),
                    "sql": "\n\n".join(t["_stmts"]) + "\n"})
    return out


def finish_funcs(sch):
    return [{"schema": f["schema"], "name": f["name"], "security_definer": f["security_definer"], "grants": f["grants"],
             "source_file": f["source_file"], "sql": "\n\n".join(f["_stmts"]) + "\n"} for f in sch.funcs.values()]


# ---------- 파일 ----------
def read(p):
    return Path(p).read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")


def rel(p):
    try:
        return str(Path(p).resolve().relative_to(ROOT)).replace("\\", "/")
    except ValueError:
        return str(p).replace("\\", "/")


def sql_files(directory, skip_check=True):
    d = Path(directory)
    if not d.is_dir():
        return []
    return sorted(f for f in d.glob("*.sql") if not (skip_check and f.name.startswith("check_")))


def build_files(structure, paths, label=None):
    return [{"structure": structure, "path": label(p) if label else rel(p), "sql": read(p)} for p in paths]


def schema_from(files):
    s = Schema()
    for f in files:
        s.feed(f["path"], f["sql"])
    return s


def parse_renames(slug):
    p = ROOT / "products" / slug / "existing.md"
    if not p.exists():
        return {}
    res = {}
    for line in read(p).splitlines():
        m = re.match(r"\|\s*`?(\w+\.\w+)`?\s*\|[^|]*\|\s*`?(nomad_\w+\.\w+)`?\s*\|", line)
        if m:
            res[m.group(2).split(".")[1]] = m.group(1)
    return res


def parse_local_storage(slug):
    p = ROOT / "products" / slug / "local-storage.md"
    if not p.exists():
        return []
    res, sec = [], False
    for line in read(p).splitlines():
        if line.startswith("## "):
            sec = line.startswith("## 2")
            continue
        if not sec or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 4:
            continue
        key = re.findall(r"`([^`]+)`", cells[1])
        if not key or not key[0].startswith("nomad."):
            continue
        res.append({"key": key[0], "platform": "-", "content": cells[2], "sync": "-", "secret": False,
                    "clear_on_logout": cells[3].startswith("삭제")})
    return res


def discover_products():
    """KNOWN 순서 뒤에 products/ 아래 나머지 제품(user·org·app 폴더가 있는 디렉터리)을 이름순으로 붙인다.
    반환: [(slug, 이름, 레포 표기, 형태, 사용처, 기존 SQL 경로 목록, 기존 경로 표기 함수)]"""
    known = {k[0]: k for k in KNOWN}
    slugs = [k[0] for k in KNOWN] + sorted(d.name for d in (ROOT / "products").iterdir()
                                           if d.is_dir() and d.name not in known and any((d / x).is_dir() for x in ("user", "org", "app")))
    out = []
    for slug in slugs:
        if slug in known:
            _, name, repo, form, clients = known[slug]
            repo_dir = DEV / repo / "supabase" / "migrations"
            if not repo_dir.is_dir():
                print(f"  경고: 기존 레포 migrations 없음 — {repo_dir}", file=sys.stderr)
            out.append((slug, name, repo, form, clients, sql_files(repo_dir, skip_check=False),
                        lambda p, r=repo: f"{r}/supabase/migrations/{p.name}"))
            continue
        # 이름 = existing.md 제목의 "기존 DB" 앞부분, 원본 = "원본:" 줄의 첫 `경로`(.sql 파일 또는 폴더, 실제로 있을 때만)
        md = ROOT / "products" / slug / "existing.md"
        head = read(md) if md.exists() else ""
        m = re.search(r"^#\s+(.+?)\s+기존 DB", head, re.M)
        name = m.group(1).strip() if m else slug
        form = "user" if (ROOT / "products" / slug / "user").is_dir() else "org"
        clients = ["web"] + (["worker"] if "워커=" in head else [])
        src, repo = [], "-"
        m = re.search(r"^원본:\s*`([^`]+)`", head, re.M)
        if m:
            sp = Path(m.group(1))
            if not sp.is_absolute():
                sp = DEV / sp
            if sp.is_file() and sp.suffix == ".sql":
                src = [sp]
            elif sp.is_dir():
                src = sql_files(sp, skip_check=False)
            if src:
                repo = rel_to(sp, DEV)
        out.append((slug, name, repo, form, clients, src, lambda p: rel_to(p, DEV)))
    return out


def rel_to(p, base):
    try:
        return str(Path(p).relative_to(base)).replace("\\", "/")
    except ValueError:
        return Path(p).name


def core_area_of(name, tables_by_area, kind):
    for area, names, pat in CORE_AREAS:
        if kind == "t" and name in names:
            return area
    for area, _, pat in CORE_AREAS:
        if kind == "f" and re.search(pat, name, re.I) and area != "계정·조직":
            return area
    return CORE_AREAS[0][0]


# ---------- 본문 ----------
def main():
    prod_out = []
    bundles = []
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8"); sys.stderr.reconfigure(encoding="utf-8")
    # 코어
    core_paths = sorted((ROOT / "supabase" / "migrations").glob("*nomad_core*.sql"))
    core_files = build_files("core", core_paths)
    core_sch = schema_from(core_files)
    core_tables = [t for t in finish_tables(core_sch) if t["schema"].startswith("nomad_core")]
    core_funcs = [f for f in finish_funcs(core_sch) if f["schema"].startswith("nomad_core")]
    areas = {a[0]: {"name": a[0], "tables": [], "functions": []} for a in CORE_AREAS}
    for t in core_tables:
        areas[core_area_of(t["name"], None, "t")]["tables"].append(t)
    for f in core_funcs:
        areas[core_area_of(f["name"], None, "f")]["functions"].append(f)
    core = {"areas": [a for a in areas.values() if a["tables"] or a["functions"]], "files": core_files}

    products = discover_products()
    for slug, name, repo, form, clients, ex_paths, ex_label in products:
        pdir = ROOT / "products" / slug
        renames = parse_renames(slug)
        ex_files = build_files("existing", ex_paths, ex_label)
        app = sql_files(pdir / "app")
        single_files = build_files("single", sql_files(pdir / "user") + app)
        tenant_files = build_files("tenant", sql_files(pdir / "org") + app)
        mono_files = build_files("monorepo", [p for p in sql_files(ROOT / "bundles" / "monorepo" / "supabase" / "migrations") if f"_{slug}_" in p.name])
        variants, files = {}, []
        for key, fl in (("existing", ex_files), ("single", single_files), ("tenant", tenant_files), ("monorepo", mono_files)):
            tabs = finish_tables(schema_from(fl), renames=None if key == "existing" else renames)
            variants[key] = {"tables": tabs}
            files.extend(fl)
        prod_out.append({"slug": slug, "name": name, "repo": repo, "form": form, "clients": clients, "placeholder": False,
                         "note": f"products/{slug}/existing.md · " + (f"원본 {len(ex_files)}개 SQL 최종 상태" if ex_files else "기존 SQL 없음"),
                         "variants": variants, "local_storage": parse_local_storage(slug), "files": files})

    # 번들 전체 SQL (단일·테넌트·모노레포) — 이어 붙여 data/bundles/*.sql 로 쓴다. bundles/ 가 없으면 건너뛴다(화면에서 숨김).
    bundle_texts = {}
    for structure, slug, folder in [("single", p[0], ROOT / "bundles" / "single" / p[0]) for p in products] + \
                                   [("tenant", p[0], ROOT / "bundles" / "tenant" / p[0]) for p in products] + \
                                   [("monorepo", None, ROOT / "bundles" / "monorepo")]:
        files = sorted((folder / "supabase" / "migrations").glob("*.sql"))
        if not files:
            continue
        fname = f"{structure}-{slug}.sql" if slug else f"{structure}.sql"
        text = "".join(f"-- ==== {f.name} ====\n{read(f).rstrip()}\n\n" for f in files)
        bundle_texts[fname] = text
        bundles.append({"structure": structure, "slug": slug, "file": f"data/bundles/{fname}", "files": len(files), "bytes": len(text.encode("utf-8"))})

    tz = timezone(timedelta(hours=9))
    data = {"generated_at": datetime.now(tz).isoformat(timespec="seconds"), "products": prod_out, "core": core, "bundles": bundles}
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))  # 한 줄(용량 절약)
    for label, body in [("schema.json", text)] + [(f"bundles/{k}", v) for k, v in bundle_texts.items()]:
        hit = find_secret(body)
        if hit:  # 아무것도 쓰기 전에 멈춘다
            print(f"실패: 비밀 패턴 발견 ({label}) — {hit[:12]}…", file=sys.stderr)
            sys.exit(1)
    bdir = OUT.parent / "bundles"
    bdir.mkdir(parents=True, exist_ok=True)
    for old in bdir.glob("*.sql"):
        old.unlink()
    for fname, body in bundle_texts.items():
        (bdir / fname).write_text(body, encoding="utf-8", newline="\n")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"생성: {OUT} ({len(text) // 1024} KiB)")
    print(f"core: 테이블 {sum(len(a['tables']) for a in core['areas'])} · 함수 {sum(len(a['functions']) for a in core['areas'])}")
    for p in prod_out:
        print(p["slug"], {k: len(v["tables"]) for k, v in p["variants"].items()}, "files", len(p["files"]))


if __name__ == "__main__":
    main()
