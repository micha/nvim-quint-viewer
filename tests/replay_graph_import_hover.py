"""Replay imported hover against Neovim and the upstream Quint language server."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_import_hover.qnt'
FIXTURE = ROOT / 'tests/fixtures/graph_import_hover'
HISTORIES = {'freshImportedHoverTest', 'freshLocalHoverTest', 'dirtyCallerRefusesImportedHoverTest',
             'movedPolicyRefusesImportedHoverTest', 'dirtyPolicyRefusesImportedHoverTest',
             'movedPolicyDoesNotBlockLocalHoverTest', 'importedReferencesDoNothingTest'}


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module graph_import_hover_verdicts {', '  import graph_import_hover.* from "./graph_import_hover"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        shutil.copytree(FIXTURE, case)
        observations = observe(history, requests, case, case / 'caller.qnt', worktree,
                               'replay_graph_import_hover.lua')
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    def control(name, history, **changed):
        requests, views = replays[history]
        tests.append(verdict_test(name, requests, [*views[:-1], {**views[-1], **changed}]))
        return name

    imported = replays['freshImportedHoverTest'][1][-1]
    local = replays['freshLocalHoverTest'][1][-1]
    controls = [
        control('sameNamedLocalHoverRejectedTest', 'freshImportedHoverTest', hover=local['hover']),
        control('wrongImportedHoverOriginRejectedTest', 'freshImportedHoverTest', lookups=local['lookups']),
        control('staleImportedHoverRequestRejectedTest', 'movedPolicyRefusesImportedHoverTest',
                lookups=imported['lookups']),
    ]
    verdicts = directory / 'graph_import_hover_verdicts.qnt'
    verdicts.write_text('\n\n'.join(tests) + '\n}\n', encoding='utf-8')
    check_verdicts(verdicts, directory / 'verdicts', names)
    for name in controls:
        check_rejection(verdicts, name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', action='store_true', help='load the plugin from the checkout instead of Git HEAD')
    args = parser.parse_args()
    if shutil.which('quint-language-server') is None:
        parser.exit(1, 'quint-language-server is required; see spec/README.md\n')
    try:
        with tempfile.TemporaryDirectory(prefix='qmodel-import-hover-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint imported hover replay: {error}\n')


if __name__ == '__main__':
    main()
