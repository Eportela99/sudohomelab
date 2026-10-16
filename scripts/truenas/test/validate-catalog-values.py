"""Check catalog-app values against the official TrueNAS questions.yaml schemas.

usage: validate-catalog-values.py VALUES_DIR SCHEMA_DIR
  VALUES_DIR  <app>.json files written by the installer (.catalog/)
  SCHEMA_DIR  <app>/questions.yaml from github.com/truenas/apps (ix-dev/<train>/<app>)

Reports keys the schema doesn't know (would be rejected), enum/type mismatches,
and required fields without a default that we didn't provide.
"""
import json
import os
import sys

import yaml

values_dir, schema_dir = sys.argv[1:3]
problems = 0


def report(app, path, msg):
    global problems
    problems += 1
    print(f'  ✗ {app}: {".".join(path) or "<root>"}: {msg}')


def check(app, value, schema, path):
    t = schema.get('type')
    if t == 'dict':
        attrs = {a['variable']: a['schema'] for a in schema.get('attrs', [])}
        if not isinstance(value, dict):
            return report(app, path, f'expected dict, got {type(value).__name__}')
        for k, v in value.items():
            if k not in attrs:
                report(app, path + [k], 'unknown key')
            else:
                check(app, v, attrs[k], path + [k])
        for k, s in attrs.items():
            if k not in value and s.get('required') and 'default' not in s and not s.get('show_if'):
                report(app, path + [k], 'required, no default, not provided')
    elif t == 'list':
        if not isinstance(value, list):
            return report(app, path, 'expected list')
        items = schema.get('items', [])
        if items:
            for i, item in enumerate(value):
                check(app, item, items[0]['schema'], path + [str(i)])
    elif t == 'int':
        if not isinstance(value, int) or isinstance(value, bool):
            report(app, path, f'expected int, got {value!r}')
    elif t == 'boolean':
        if not isinstance(value, bool):
            report(app, path, f'expected bool, got {value!r}')
    elif t in ('string', 'path', 'hostpath', 'ipaddr', 'uri'):
        if not isinstance(value, str):
            report(app, path, f'expected string, got {value!r}')
        enum = [e['value'] for e in schema.get('enum', [])]
        if enum and value not in enum:
            report(app, path, f'{value!r} not in {enum}')


for f in sorted(os.listdir(values_dir)):
    app = f[:-5]
    q = yaml.safe_load(open(os.path.join(schema_dir, app, 'questions.yaml')))
    root = {'type': 'dict', 'attrs': q['questions']}
    before = problems
    check(app, json.load(open(os.path.join(values_dir, f))), root, [])
    if problems == before:
        print(f'  ✓ {app}')
print(f'\n{problems} problem(s)')
sys.exit(1 if problems else 0)
