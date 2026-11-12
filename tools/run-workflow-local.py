#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Run one of the build workflows on this machine, step by step, without GitHub or Docker.

    python3 tools/run-workflow-local.py .github/workflows/build-deps.yml \
        [--input rebuild=false] [--from 'OCCT'] [--only 'VTK'] [--skip 'Install emsdk']

The build lanes (build-qt-wasm, build-deps, build-python-deps, build-freecad,
link-freecad) are single-job workflows whose real work is in `run:` blocks. This runs
those blocks with bash in the repository root, with the GitHub expression subset the
lanes use (`inputs.*`, `env.*`, `steps.<id>.outputs.*`/`.outcome`, `github.*`,
`always()/success()/failure()`, `hashFiles()`, `fromJSON()`, `&& || ! == !=`), and
with GITHUB_ENV / GITHUB_OUTPUT / GITHUB_PATH / GITHUB_STEP_SUMMARY files.

`uses:` steps are not run: actions/checkout (the tree is already here), actions/cache
(the outputs of a previous local run stay on disk, which is what a cache hit means),
upload-artifact (logs stay in /tmp). Two get a local meaning:
  - actions/cache for emsdk reports cache-hit=true when ./emsdk/upstream exists;
  - actions/setup-python puts FCWEB_HOST_PYTHON's directory first on PATH.
"""
import argparse, fnmatch, glob, hashlib, json, os, re, subprocess, sys, tempfile, time

try:
    import yaml
except ImportError:
    sys.exit("needs PyYAML (pip install pyyaml)")


class Loader(yaml.SafeLoader):
    """YAML 1.2 booleans, as GitHub reads workflows: `on`/`off`/`yes`/`no` stay strings."""


Loader.yaml_implicit_resolvers = {
    k: [(tag, rx) for tag, rx in v if tag != 'tag:yaml.org,2002:bool']
    for k, v in yaml.SafeLoader.yaml_implicit_resolvers.copy().items()}
Loader.add_implicit_resolver('tag:yaml.org,2002:bool', re.compile(r'^(?:true|True|TRUE|false|False|FALSE)$'),
                             list('tTfF'))


class Ctx(dict):
    """Attribute access that returns '' for anything missing, like GitHub does."""
    def __getattr__(self, k):
        v = self.get(k, '')
        return Ctx(v) if isinstance(v, dict) and not isinstance(v, Ctx) else v


TOK = re.compile(r"""\s*(?:
    (?P<str>'(?:[^']|'')*') |
    (?P<num>\d+(?:\.\d+)?\b) |
    (?P<op>==|!=|&&|\|\||!|\(|\)|,|<=|>=|<|>) |
    (?P<name>[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z_*][A-Za-z0-9_\-]*)*)
)""", re.X)


def to_python(expr):
    out = []
    pos = 0
    expr = expr.strip()
    while pos < len(expr):
        m = TOK.match(expr, pos)
        if pos < len(expr) and expr[pos:].strip() == '':
            break
        if not m or m.end() == pos:
            raise ValueError(f"cannot parse expression at {expr[pos:]!r}")
        pos = m.end()
        if m.group('str') is not None:
            out.append(repr(m.group('str')[1:-1].replace("''", "'")))
        elif m.group('num') is not None:
            out.append(m.group('num'))
        elif m.group('op') is not None:
            op = m.group('op')
            out.append({'&&': ' and ', '||': ' or ', '!': ' not '}.get(op, op))
        else:
            n = m.group('name')
            if n in ('true', 'false', 'null'):
                out.append({'true': 'True', 'false': 'False', 'null': 'None'}[n])
            elif pos < len(expr) and expr[pos:].lstrip().startswith('('):
                out.append('F_' + n)
            else:
                parts = n.split('.')
                s = f"C[{parts[0]!r}]"
                for p in parts[1:]:
                    s = f"G({s},{p!r})"
                out.append(s)
    return ''.join(out).strip()


def G(obj, key):
    if isinstance(obj, dict):
        return obj.get(key, '')
    return ''


def eq(a, b):
    # GitHub compares strings case-insensitively and coerces booleans/numbers loosely
    norm = lambda v: str(v).lower() if not isinstance(v, str) else v.lower()
    return norm(a) == norm(b)


class Runner:
    def __init__(self, wf_path, inputs, root, only, start, skip, stop):
        self.root = root
        self.wf = yaml.load(open(wf_path), Loader=Loader)
        on = self.wf.get('on') or self.wf.get(True)
        defaults = {k: v.get('default', '') for k, v in
                    ((on.get('workflow_dispatch') or {}).get('inputs') or {}).items()}
        for k, v in inputs.items():
            if v in ('true', 'false'):
                v = v == 'true'
            defaults[k] = v
        self.inputs = defaults
        self.env = {k: str(v) for k, v in (self.wf.get('env') or {}).items()}
        self.steps = {}
        self.failed = False
        self.only, self.start, self.skip, self.stop = only, start, skip, stop
        self.tmp = tempfile.mkdtemp(prefix='fcweb-wf-')
        self.path_prepend = []

    # -- expressions -------------------------------------------------------
    def ctx(self):
        return {
            'inputs': self.inputs, 'env': {**os.environ, **self.env},
            'steps': self.steps, 'secrets': {},
            'github': {'workspace': self.root, 'run_id': str(int(time.time())),
                       'token': '', 'ref_name': 'local', 'sha': self._sha()},
            'runner': {'os': 'Linux', 'temp': self.tmp, 'arch': 'X64'},
            'job': {'status': 'failure' if self.failed else 'success'},
        }

    def _sha(self):
        try:
            return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.root,
                                           text=True).strip()
        except Exception:
            return ''

    def evaluate(self, expr):
        py = to_python(expr)
        fns = {
            'F_always': lambda: True,
            'F_success': lambda: not self.failed,
            'F_failure': lambda: self.failed,
            'F_cancelled': lambda: False,
            'F_hashFiles': self.hash_files,
            'F_fromJSON': json.loads,
            'F_toJSON': json.dumps,
            'F_format': lambda f, *a: re.sub(r'\{(\d+)\}', lambda m: str(a[int(m.group(1))]), f),
            'F_contains': lambda a, b: (str(b).lower() in str(a).lower()) if isinstance(a, str) else b in a,
            'F_startsWith': lambda a, b: str(a).lower().startswith(str(b).lower()),
            'F_endsWith': lambda a, b: str(a).lower().endswith(str(b).lower()),
        }
        # route == / != through eq() for GitHub's loose comparison
        tree = py
        tree = re.sub(r'==', ' __EQ__ ', tree)
        tree = re.sub(r'!=', ' __NE__ ', tree)
        env = {'C': self.ctx(), 'G': G, **fns}
        if '__EQ__' in tree or '__NE__' in tree:
            return self._eval_cmp(tree, env)
        return eval(tree, env)

    def _eval_cmp(self, tree, env):
        # Wrap each comparison: split on and/or/not/parens is overkill; instead rewrite
        # `X __EQ__ Y` with a small precedence-aware pass using Python's ast after
        # substituting a custom operator class.
        class V:
            def __init__(s, v): s.v = v
        src = tree.replace('__EQ__', '==').replace('__NE__', '!=')
        import ast
        node = ast.parse(src, mode='eval')

        class T(ast.NodeTransformer):
            def visit_Compare(s, n):
                s.generic_visit(n)
                if len(n.ops) == 1 and isinstance(n.ops[0], (ast.Eq, ast.NotEq)):
                    call = ast.Call(func=ast.Name('EQ', ast.Load()),
                                    args=[n.left, n.comparators[0]], keywords=[])
                    if isinstance(n.ops[0], ast.NotEq):
                        return ast.UnaryOp(ast.Not(), call)
                    return call
                return n
        node = ast.fix_missing_locations(T().visit(node))
        return eval(compile(node, '<expr>', 'eval'), {**env, 'EQ': eq})

    def hash_files(self, *patterns):
        h = hashlib.sha256()
        files = set()
        for p in patterns:
            files.update(f for f in glob.glob(os.path.join(self.root, p), recursive=True)
                         if os.path.isfile(f))
        if not files:
            return ''
        for f in sorted(files):
            h.update(hashlib.sha256(open(f, 'rb').read()).digest())
        return h.hexdigest()

    def render(self, s):
        if not isinstance(s, str):
            return s
        def sub(m):
            v = self.evaluate(m.group(1))
            if isinstance(v, bool):
                return 'true' if v else 'false'
            return '' if v is None else str(v)
        return re.sub(r'\$\{\{(.*?)\}\}', sub, s, flags=re.S)

    def cond(self, s):
        if s is None:
            return not self.failed
        if isinstance(s, bool):
            return s
        s = str(s).strip()
        m = re.fullmatch(r'\$\{\{(.*)\}\}', s, flags=re.S)
        if m:
            s = m.group(1)
        v = self.evaluate(s)
        # a condition without a status function implies success() &&
        if not re.search(r'\b(always|failure|cancelled|success)\(', s):
            return bool(v) and not self.failed
        return bool(v)

    # -- files ---------------------------------------------------------------
    @staticmethod
    def read_kv(path):
        out = {}
        if not os.path.exists(path):
            return out
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
        i = 0
        while i < len(lines):
            line = lines[i]
            if '<<' in line and ('=' not in line or line.index('<<') < line.index('=')):
                k, delim = line.split('<<', 1)
                buf = []
                i += 1
                while i < len(lines) and lines[i] != delim:
                    buf.append(lines[i]); i += 1
                out[k] = '\n'.join(buf)
            elif '=' in line:
                k, v = line.split('=', 1)
                out[k] = v
            i += 1
        return out

    # -- steps ---------------------------------------------------------------
    def run(self):
        (job_name, job), = self.wf['jobs'].items()
        self.env.update({k: self.render(str(v)) for k, v in (job.get('env') or {}).items()})
        started = self.start is None
        summary = os.path.join(self.tmp, 'summary.md')
        for i, step in enumerate(job['steps']):
            name = self.render(step.get('name') or step.get('uses') or f'step {i}')
            sid = step.get('id')
            if not started and self.start and (self.start.lower() in name.lower() or str(i) == self.start):
                started = True
            if not started:
                continue
            if self.only and not any(o.lower() in name.lower() or str(i) == o for o in self.only):
                continue
            if any(s.lower() in name.lower() or str(i) == s for s in self.skip):
                print(f"\n----- [{i}] {name}: SKIPPED (--skip)", flush=True)
                continue
            if not self.cond(step.get('if')):
                print(f"\n----- [{i}] {name}: condition false, not run", flush=True)
                continue
            if 'uses' in step:
                self.uses(step, sid, name, i)
                continue
            print(f"\n===== [{i}] {name}", flush=True)
            t0 = time.time()
            script = self.render(step['run'])
            senv = dict(os.environ)
            senv.update(self.env)
            senv.update({k: self.render(str(v)) for k, v in (step.get('env') or {}).items()})
            files = {n: os.path.join(self.tmp, f'{n}-{i}') for n in ('env', 'output', 'path')}
            for f in files.values():
                open(f, 'w').close()
            senv.update({
                'GITHUB_WORKSPACE': self.root, 'GITHUB_ENV': files['env'],
                'GITHUB_OUTPUT': files['output'], 'GITHUB_PATH': files['path'],
                'GITHUB_STEP_SUMMARY': summary, 'GITHUB_ACTIONS': 'true', 'CI': 'true',
                'RUNNER_TEMP': self.tmp, 'RUNNER_OS': 'Linux', 'GITHUB_RUN_ID': str(int(t0)),
            })
            if self.path_prepend:
                senv['PATH'] = ':'.join(self.path_prepend) + ':' + senv.get('PATH', '')
            sf = os.path.join(self.tmp, f'step-{i}.sh')
            open(sf, 'w').write(script)
            # GitHub: no `shell:` -> `bash -e {0}`; an explicit `shell: bash` adds pipefail.
            shell = step.get('shell')
            if shell is None:
                cmd = ['bash', '--noprofile', '--norc', '-e', sf]
            elif shell == 'bash':
                cmd = ['bash', '--noprofile', '--norc', '-eo', 'pipefail', sf]
            else:
                cmd = [shell, sf]
            cwd = os.path.join(self.root, self.render(step.get('working-directory', '.')))
            rc = subprocess.call(cmd, cwd=cwd, env=senv)
            dt = time.time() - t0
            self.env.update(self.read_kv(files['env']))
            for p in open(files['path']).read().split():
                self.path_prepend.insert(0, p)
            outcome = 'success' if rc == 0 else 'failure'
            coe = step.get('continue-on-error', False)
            coe = self.render(coe) if isinstance(coe, str) else coe
            coe = coe in (True, 'true')
            if sid:
                self.steps[sid] = {'outputs': self.read_kv(files['output']), 'outcome': outcome,
                                   'conclusion': 'success' if (rc == 0 or coe) else 'failure'}
            print(f"----- [{i}] {name}: {outcome} (rc={rc}, {dt:.0f}s)"
                  f"{' [continue-on-error]' if rc and coe else ''}", flush=True)
            if rc and not coe:
                self.failed = True
            if self.stop and (self.stop.lower() in name.lower() or str(i) == self.stop):
                break
        print(f"\nsummary: {summary}")
        return 1 if self.failed else 0

    def uses(self, step, sid, name, i):
        u = step['uses']
        w = step.get('with') or {}
        out = {}
        if u.startswith('actions/cache') and 'emsdk' in str(w.get('path', '')):
            hit = os.path.isdir(os.path.join(self.root, 'emsdk', 'upstream'))
            out = {'cache-hit': 'true' if hit else 'false'}
        elif u.startswith('actions/cache'):
            path = self.render(str(w.get('path', ''))).split('\n')[0].strip()
            hit = bool(path) and os.path.exists(os.path.join(self.root, path))
            out = {'cache-hit': 'true' if hit else 'false',
                   'cache-matched-key': self.render(str(w.get('key', ''))) if hit else ''}
        elif u.startswith('actions/setup-python'):
            py = os.environ.get('FCWEB_HOST_PYTHON')
            if py:
                self.path_prepend.insert(0, os.path.dirname(py))
                out = {'python-path': py, 'python-version': w.get('python-version', '')}
            else:
                print("  setup-python: FCWEB_HOST_PYTHON not set, using the PATH python3")
                out = {'python-path': subprocess.check_output(['which', 'python3'], text=True).strip()}
        print(f"\n----- [{i}] {name}: uses {u.split('@')[0]} (local: {out or 'no-op'})", flush=True)
        if sid:
            self.steps[sid] = {'outputs': out, 'outcome': 'success', 'conclusion': 'success'}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('workflow')
    ap.add_argument('--input', action='append', default=[], help='name=value')
    ap.add_argument('--only', action='append', default=[], help='run only steps matching (name substring or index)')
    ap.add_argument('--from', dest='start', help='start at the first step matching')
    ap.add_argument('--stop-after', dest='stop', help='stop after the step matching')
    ap.add_argument('--skip', action='append', default=[], help='skip steps matching')
    a = ap.parse_args()
    root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True,
                                   cwd=os.path.dirname(os.path.abspath(a.workflow))).strip()
    inputs = dict(kv.split('=', 1) for kv in a.input)
    sys.exit(Runner(a.workflow, inputs, root, a.only, a.start, a.skip, a.stop).run())


if __name__ == '__main__':
    main()
