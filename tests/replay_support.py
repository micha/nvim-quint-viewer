"""Shared ITF trace loading and Quint verdict generation for the viewer replays."""

import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_command(module):
    return ['quint', 'test', str(module), '--backend=typescript', '--seed=1']


def quint_test(module, trace_dir, match=None):
    trace_dir.mkdir()
    command = test_command(module) + [f'--out-itf={trace_dir}/{{test}}_{{seq}}.itf.json']
    if match is not None:
        command += ['--match', match]
    subprocess.run(command, cwd=module.parent, check=True, timeout=60)
    traces = {}
    for path in sorted(trace_dir.glob('*.itf.json')):
        match = re.fullmatch(r'([a-zA-Z][a-zA-Z0-9_]*Test)_\d+\.itf\.json', path.name)
        if not match or match[1] in traces or not path.stat().st_size:
            raise ValueError(f'Expected one ITF trace per named test, got {path.name}')
        traces[match[1]] = path
    return traces


def quint_literal(value):
    if type(value) is bool:
        return 'true' if value else 'false'
    if type(value) is int:
        return str(value)
    # Quint 0.33.1 does not decode JSON escape sequences in source strings.
    if isinstance(value, str) and re.fullmatch(r'[\x20-\x21\x23-\x5b\x5d-\x7e]*', value):
        return json.dumps(value)
    if isinstance(value, dict) and all(re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_]*', key) for key in value):
        return '{ ' + ', '.join(f'{key}: {quint_literal(item)}' for key, item in value.items()) + ' }'
    if isinstance(value, list):
        return 'List(' + ', '.join(map(quint_literal, value)) + ')'
    raise ValueError(f'Cannot encode Quint evidence value: {value!r}')


def read_requests(path):
    # Pass only the request sequence to Neovim, not the model's expected view.
    requests = [state['session']['request'] for state in json.loads(path.read_text(encoding='utf-8'))['states']]
    if not requests or requests[0] != {'op': 'init', 'arg': ''}:
        raise ValueError(f'{path.name}: expected an init request')
    for request in requests:
        if (not isinstance(request, dict) or request.keys() != {'op', 'arg'}
                or not all(isinstance(field, str) for field in request.values())):
            raise ValueError(f'{path.name}: malformed request {request!r}')
    return requests


def observe(history, requests, directory, source, worktree, interpreter, **environment):
    inputs, outputs = directory / 'requests.json', directory / 'observations.json'
    inputs.write_text(json.dumps(requests), encoding='utf-8')
    env = {**os.environ, 'QMODEL_ROOT': str(ROOT), 'QMODEL_MODE': '--worktree' if worktree else '',
           'QMODEL_SOURCE': str(source), 'NVIM_APPNAME': 'nvim', **environment}
    env.update({f'XDG_{key}_HOME': str(directory / key.lower()) for key in ('CONFIG', 'DATA', 'STATE', 'CACHE')})
    print(f'Replaying {history}', flush=True)
    subprocess.run(['nvim', '--headless', '--cmd', 'set loadplugins columns=150',
                    '--cmd', 'let g:loaded_remote_plugins = 1', '-u', str(ROOT / 'tests/init.lua'),
                    '-n', '-l', str(ROOT / 'tests' / interpreter), str(inputs), str(outputs)],
                   cwd=directory, env=env, check=True, timeout=45)
    observations = json.loads(outputs.read_text(encoding='utf-8'))
    if not isinstance(observations, list) or len(observations) != len(requests):
        raise ValueError(f'{history}: expected one observation per request')
    return observations


def verdict_test(history, requests, observations):
    lines = [f'  run {history} = init']
    for step, (request, observation) in enumerate(zip(requests, observations, strict=True)):
        if step:
            lines.append(f'    .then(perform({quint_literal(request)}))')
        lines.append(f'    .expect(observationMatches({quint_literal(observation)}))')
    return '\n'.join(lines)


def check_verdicts(module, directory, names):
    # Imports also bring the original run definitions into the verdict module.
    match = '^(' + '|'.join(sorted(names)) + ')$'
    if quint_test(module, directory, match).keys() != names:
        raise ValueError('Expected a Quint verdict for each replay')


def check_rejection(module, control):
    report = module.with_suffix('.json')
    result = subprocess.run(test_command(module) + ['--match', f'^{control}$', f'--out={report}'],
                            cwd=module.parent, timeout=60)
    verdict = json.loads(report.read_text(encoding='utf-8'))
    if (result.returncode != 1 or verdict.get('stage') != 'testing' or verdict.get('errors') != []
            or verdict.get('passed') != [] or verdict.get('failed') != [control]):
        raise ValueError(f'Quint did not reject {control} as a failed test')
    print(f'Quint rejected {control}.')
