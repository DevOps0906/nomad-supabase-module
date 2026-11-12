#!/usr/bin/env bash
# 서비스 DB 청사진(blueprints/) 규칙 검증기. 실패 시 종료 코드 1.
# 사용법: bash scripts/validate-blueprints.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY=python3; "$PY" -c '' 2>/dev/null || PY=python
exec "$PY" -I - "$ROOT" <<'PY'
import os, re, sys, glob
sys.stdout.reconfigure(encoding='utf-8')
root = sys.argv[1]; bp = os.path.join(root, 'blueprints'); errors = []; n = 0
reg = open(os.path.join(bp, 'registry.yaml'), encoding='utf-8').read()
reg_slugs = re.findall(r'^\s*- slug:\s*(\S+)', reg, re.M)
for tdir in ('org', 'user', 'isolated'):
    for d in sorted(glob.glob(os.path.join(bp, tdir, '*'))):
        slug = os.path.basename(d); n += 1; rel = 'blueprints/%s/%s' % (tdir, slug)
        py = os.path.join(d, 'blueprint.yaml')
        if not os.path.exists(py): errors.append('%s: blueprint.yaml 없음' % rel); continue
        y = open(py, encoding='utf-8').read()
        m = re.search(r'^type:\s*(\S+)', y, re.M)
        if not m or m.group(1) != tdir: errors.append('%s: type이 폴더(%s)와 다름' % (rel, tdir))
        m = re.search(r'^slug:\s*(\S+)', y, re.M)
        if not m or m.group(1) != slug: errors.append('%s: slug가 폴더명과 다름' % rel)
        if slug not in reg_slugs: errors.append('%s: blueprints/registry.yaml에 없음' % rel)
        if not os.path.exists(os.path.join(d, 'README.md')): errors.append('%s: README.md 없음' % rel)
        sqlp = os.path.join(d, 'schema.draft.sql')
        if not os.path.exists(sqlp): errors.append('%s: schema.draft.sql 없음' % rel); continue
        sql = open(sqlp, encoding='utf-8').read()
        schema = re.search(r'^schema:\s*(\S+)', y, re.M).group(1)
        tables = re.findall(r'create table\s+([\w.]+)', sql, re.I)
        rls = set(re.findall(r'alter table\s+([\w.]+)\s+enable row level security', sql, re.I))
        for t in tables:
            if t not in rls: errors.append('%s: %s RLS 미활성' % (rel, t))
            if tdir == 'org':
                body = re.search(r'create table\s+%s\s*\((.*?)\n\);' % re.escape(t), sql, re.S | re.I)
                if body and 'organization_id' not in body.group(1): errors.append('%s: %s에 organization_id 없음' % (rel, t))
        for ref in re.findall(r'references\s+([\w]+)\.', sql, re.I):
            allowed = {schema, 'auth'} if tdir == 'isolated' else {schema, 'nomad_core', 'auth'}
            if ref not in allowed: errors.append('%s: 스키마 간 참조 금지 (%s)' % (rel, ref))
for s in reg_slugs:
    if not glob.glob(os.path.join(bp, '*', s)): errors.append('registry: %s 폴더 없음' % s)
if re.search(r'(eyJ[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|postgres(ql)?://\S+:\S+@)', ''.join(open(f, encoding='utf-8', errors='ignore').read() for f in glob.glob(bp + '/**/*', recursive=True) if os.path.isfile(f))):
    errors.append('비밀값으로 보이는 문자열 발견')
print('검사한 청사진: %d' % n)
if errors:
    print('실패 %d건' % len(errors)); [print(' -', e) for e in errors]; sys.exit(1)
print('OK: 모든 검사 통과')
PY
