#!/usr/bin/env bash
# 저장소 규칙 검증기. 실패 시 종료 코드 1.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I - "$ROOT" <<'PY'
import os, re, sys, glob
root = sys.argv[1]; errors = []; n = 0
reg = open(os.path.join(root, 'registry/projects.yaml'), encoding='utf-8').read()
reg_slugs = re.findall(r'^\s*- slug:\s*(\S+)', reg, re.M)
for tdir in ('org', 'user', 'isolated', 'local'):
    for d in sorted(glob.glob(os.path.join(root, 'projects', tdir, '*'))):
        slug = os.path.basename(d); n += 1; rel = 'projects/%s/%s' % (tdir, slug)
        py = os.path.join(d, 'project.yaml')
        if not os.path.exists(py): errors.append('%s: project.yaml 없음' % rel); continue
        y = open(py, encoding='utf-8').read()
        m = re.search(r'^type:\s*(\S+)', y, re.M)
        if not m or m.group(1) != tdir: errors.append('%s: type이 폴더(%s)와 다름' % (rel, tdir))
        m = re.search(r'^slug:\s*(\S+)', y, re.M)
        if not m or m.group(1) != slug: errors.append('%s: slug가 폴더명과 다름' % rel)
        if slug not in reg_slugs: errors.append('%s: registry/projects.yaml에 없음' % rel)
        if not os.path.exists(os.path.join(d, 'README.md')): errors.append('%s: README.md 없음' % rel)
        sqlp = os.path.join(d, 'schema.draft.sql')
        if tdir == 'local':
            if os.path.exists(sqlp): errors.append('%s: local은 SQL을 두지 않음' % rel)
            continue
        if not os.path.exists(sqlp): errors.append('%s: schema.draft.sql 없음' % rel); continue
        sql = open(sqlp, encoding='utf-8').read()
        schema = re.search(r'^schema:\s*(\S+)', y, re.M).group(1)
        tables = re.findall(r'create table\s+([\w.]+)', sql, re.I)
        rls = set(re.findall(r'alter table\s+([\w.]+)\s+enable row level security', sql, re.I))
        for t in tables:
            if t not in rls: errors.append('%s: %s RLS 미활성' % (rel, t))
            if tdir == 'org':
                body = re.search(r'create table\s+%s\s*\((.*?)\n\);' % re.escape(t), sql, re.S | re.I)
                if body and 'org_id' not in body.group(1): errors.append('%s: %s에 org_id 없음' % (rel, t))
        for ref in re.findall(r'references\s+([\w]+)\.', sql, re.I):
            allowed = {schema, 'auth'} if tdir == 'isolated' else {schema, 'core', 'auth'}
            if ref not in allowed: errors.append('%s: 스키마 간 참조 금지 (%s)' % (rel, ref))
for s in reg_slugs:
    if not glob.glob(os.path.join(root, 'projects', '*', s)): errors.append('registry: %s 폴더 없음' % s)
if re.search(r'(eyJ[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|postgres(ql)?://\S+:\S+@)', ''.join(open(f, encoding='utf-8', errors='ignore').read() for f in glob.glob(root + '/**/*', recursive=True) if os.path.isfile(f) and not f.endswith('.sh'))):
    errors.append('비밀값으로 보이는 문자열 발견')
print('검사한 프로젝트: %d' % n)
if errors:
    print('실패 %d건' % len(errors)); [print(' -', e) for e in errors]; sys.exit(1)
print('OK: 모든 검사 통과')
PY
