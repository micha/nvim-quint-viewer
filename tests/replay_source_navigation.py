"""Replay Quint's source-navigation histories in Neovim and ask Quint to judge the observations."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/source_navigation.qnt'
HISTORIES = {'freshLocalDefinitionTest', 'freshOperatorDefinitionTest', 'changedAfterOpenTest'}
CONTROL = 'warningAndJumpRejectedTest'


def observe_artifact(history, requests, directory, worktree):
    directory.mkdir()
    source = directory / 'approval.qnt'
    artifact = directory / 'approval.qmodel.json'
    shutil.copyfile(ROOT / 'examples/approval.qnt', source)
    subprocess.run(['python3', '-B', str(ROOT / 'tools/export_model.py'), str(source), 'review',
                    '-o', str(artifact)], cwd=directory, check=True, timeout=60)
    return observe(history, requests, directory, source, worktree, 'replay_source_navigation.lua',
                   QMODEL_ARTIFACT=str(artifact))


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
        observations = observe_artifact(history, requests, directory / history, worktree)
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
    check_verdicts(verdicts, directory / 'verdicts', names)
    check_rejection(verdicts, CONTROL)


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
