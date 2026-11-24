"""Replay Quint's source-navigation histories in Neovim and ask Quint to judge the observations."""

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / 'spec/source_navigation.qnt'
HISTORIES = {'freshLocalDefinitionTest', 'freshOperatorDefinitionTest', 'changedAfterOpenTest'}
CONTROL = 'warningAndJumpRejectedTest'


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


def observe(history, requests, directory, worktree):
    directory.mkdir()
    source = directory / 'approval.qnt'
    artifact = directory / 'approval.qmodel.json'
    shutil.copyfile(ROOT / 'examples/approval.qnt', source)
    subprocess.run(['python3', '-B', str(ROOT / 'tools/export_model.py'), str(source), 'review',
                    '-o', str(artifact)], cwd=directory, check=True, timeout=60)

    inputs, outputs = directory / 'requests.json', directory / 'observations.json'
    inputs.write_text(json.dumps(requests), encoding='utf-8')
    env = {**os.environ, 'QMODEL_ROOT': str(ROOT), 'QMODEL_MODE': '--worktree' if worktree else '',
           'QMODEL_ARTIFACT': str(artifact), 'QMODEL_SOURCE': str(source), 'NVIM_APPNAME': 'nvim'}
    env.update({f'XDG_{key}_HOME': str(directory / key.lower()) for key in ('CONFIG', 'DATA', 'STATE', 'CACHE')})
    print(f'Replaying {history}', flush=True)
    subprocess.run(['nvim', '--headless', '--cmd', 'set loadplugins columns=150',
                    '--cmd', 'let g:loaded_remote_plugins = 1', '-u', str(ROOT / 'tests/init.lua'),
                    '-n', '-l', str(ROOT / 'tests/replay_source_navigation.lua'), str(inputs), str(outputs)],
                   cwd=directory, env=env, check=True, timeout=30)
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


def check_rejection(module):
    report = module.with_suffix('.json')
    result = subprocess.run(test_command(module) + ['--match', f'^{CONTROL}$', f'--out={report}'],
                            cwd=module.parent, timeout=60)
    verdict = json.loads(report.read_text(encoding='utf-8'))
    if (result.returncode != 1 or verdict.get('stage') != 'testing' or verdict.get('errors') != []
            or verdict.get('passed') != [] or verdict.get('failed') != [CONTROL]):
        raise ValueError('Quint did not reject the warning-plus-jump control as a failed test')
    print('Quint rejected the warning-plus-jump control.')


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    # Keep the checks in Quint: each actual view is asserted against the same
    # initial state and transitions that produced the history.
    tests = ['module source_navigation_verdicts {', '  import source_navigation.* from "./source_navigation"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        observations = observe(history, requests, directory / history, worktree)
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    # Keep the real stale warning but substitute the pane and cursor changes
    # from a real fresh jump. Run the same assertion path on the forged view.
    requests, stale = replays['changedAfterOpenTest']
    fresh = replays['freshLocalDefinitionTest'][1][-1]
    forged = {**stale[-1], **{key: fresh[key] for key in ('panes', 'focus', 'destination')}}
    tests.append(verdict_test(CONTROL, requests, [*stale[:-1], forged]))
    verdicts = directory / 'source_navigation_verdicts.qnt'
    verdicts.write_text('\n\n'.join(tests) + '\n}\n', encoding='utf-8')
    # Imports also bring the original run definitions into the verdict module.
    match = '^(' + '|'.join(sorted(names)) + ')$'
    if quint_test(verdicts, directory / 'verdicts', match).keys() != names:
        raise ValueError('Expected a Quint verdict for each replay')
    check_rejection(verdicts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', action='store_true', help='load the plugin from the checkout instead of Git HEAD')
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix='qmodel-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint source navigation replay: {error}\n')


if __name__ == '__main__':
    main()
