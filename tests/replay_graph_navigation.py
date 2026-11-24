"""Replay the source-to-graph histories against Neovim and the upstream Quint language server."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_navigation.qnt'
HISTORIES = {'freshDefinitionAndBackTest', 'dirtySourceRefusesDefinitionTest', 'diskChangeAndRegenerateTest'}
WRONG_BACK = 'wrongOriginRejectedTest'
STALE_REQUEST = 'staleRequestRejectedTest'


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module graph_navigation_verdicts {', '  import graph_navigation.* from "./graph_navigation"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        case.mkdir()
        source = case / 'approval.qnt'
        shutil.copyfile(ROOT / 'examples/approval.qnt', source)
        observations = observe(history, requests, case, source, worktree, 'replay_graph_navigation.lua')
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    # Keep all other evidence from the real run, including focus on graph and
    # the stale warning, so each control exercises one independent guarantee.
    requests, fresh = replays['freshDefinitionAndBackTest']
    tests.append(verdict_test(WRONG_BACK, requests, [*fresh[:-1], {**fresh[-1], 'atOrigin': False}]))
    requests, stale = replays['dirtySourceRefusesDefinitionTest']
    tests.append(verdict_test(STALE_REQUEST, requests, [*stale[:-1], {**stale[-1], 'definitionRequests': 1}]))

    verdicts = directory / 'graph_navigation_verdicts.qnt'
    verdicts.write_text('\n\n'.join(tests) + '\n}\n', encoding='utf-8')
    check_verdicts(verdicts, directory / 'verdicts', names)
    check_rejection(verdicts, WRONG_BACK)
    check_rejection(verdicts, STALE_REQUEST)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', action='store_true', help='load the plugin from the checkout instead of Git HEAD')
    args = parser.parse_args()
    if shutil.which('quint-language-server') is None:
        parser.exit(1, 'quint-language-server is required; see spec/README.md\n')
    try:
        with tempfile.TemporaryDirectory(prefix='qmodel-graph-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint graph navigation replay: {error}\n')


if __name__ == '__main__':
    main()
