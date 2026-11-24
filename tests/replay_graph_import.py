"""Replay cross-file graph navigation against Neovim and the upstream Quint LSP."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_import.qnt'
FIXTURE = ROOT / 'tests/fixtures/graph_import'
IMPORTED = 'importedDefinitionAndBackTest'
LOCAL = 'localDefinitionAndBackTest'
MOVED = 'movedPolicyRefreshTest'
HISTORIES = {
    IMPORTED, LOCAL, MOVED, 'dirtyCallerRefusesImportedDefinitionTest',
    'movedPolicyRefusesImportedDefinitionTest', 'dirtyPolicyRefusesImportedDefinitionTest',
    'movedPolicyDoesNotBlockLocalDefinitionTest',
}
WRONG_LOCAL = 'sameNamedLocalDefinitionRejectedTest'
WRONG_FILE = 'wrongDefinitionFileRejectedTest'
OLD_LINE = 'oldImportedDefinitionLineRejectedTest'


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if histories.keys() != HISTORIES:
        raise ValueError(f'Expected histories {sorted(HISTORIES)}, got {sorted(histories)}')

    tests = ['module graph_import_verdicts {', '  import graph_import.* from "./graph_import"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        shutil.copytree(FIXTURE, case)
        observations = observe(history, requests, case, case / 'caller.qnt', worktree, 'replay_graph_import.lua')
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    requests, imported = replays[IMPORTED]
    local_requests, local = replays[LOCAL]
    follow = {'op': 'followDefinition', 'arg': ''}
    index = requests.index(follow)
    local_landing = local[local_requests.index(follow)]
    for name, landing in (
        (WRONG_LOCAL, local_landing),
        (WRONG_FILE, {**imported[index], 'focus': local_landing['focus']}),
    ):
        # Exercise the normal assertion path; retain all other observations.
        tests.append(verdict_test(name, requests, [*imported[:index], landing, *imported[index + 1:]]))

    moved_requests, moved = replays[MOVED]
    moved_index = max(i for i, request in enumerate(moved_requests) if request == follow)
    old_landing = {**moved[moved_index], 'line': imported[index]['line']}
    tests.append(verdict_test(OLD_LINE, moved_requests,
                              [*moved[:moved_index], old_landing, *moved[moved_index + 1:]]))

    verdicts = directory / 'graph_import_verdicts.qnt'
    verdicts.write_text('\n\n'.join(tests) + '\n}\n', encoding='utf-8')
    check_verdicts(verdicts, directory / 'verdicts', names)
    check_rejection(verdicts, WRONG_LOCAL)
    check_rejection(verdicts, WRONG_FILE)
    check_rejection(verdicts, OLD_LINE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', action='store_true', help='load the plugin from the checkout instead of Git HEAD')
    args = parser.parse_args()
    if shutil.which('quint-language-server') is None:
        parser.exit(1, 'quint-language-server is required; see spec/README.md\n')
    try:
        with tempfile.TemporaryDirectory(prefix='qmodel-import-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint graph import replay: {error}\n')


if __name__ == '__main__':
    main()
