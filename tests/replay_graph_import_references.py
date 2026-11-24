"""Replay imported references against Neovim and the upstream Quint language server."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_import_references.qnt'
FIXTURE = ROOT / 'tests/fixtures/graph_import_references'
HISTORIES = {'freshImportedReferencesTest', 'openOtherCallerDoesNotBroadenReferencesTest',
             'freshLocalReferencesTest', 'dirtyCallerRefusesImportedReferencesTest',
             'dirtyPolicyRefusesImportedReferencesTest', 'movedPolicyRefusesImportedReferencesTest',
             'movedPolicyDoesNotBlockLocalReferencesTest', 'movedPolicyRefreshReferencesTest'}


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module graph_import_references_verdicts {',
             '  import graph_import_references.* from "./graph_import_references"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        shutil.copytree(FIXTURE, case)
        observations = observe(history, requests, case, case / 'caller.qnt', worktree,
                               'replay_graph_import_references.lua')
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    def control(name, history, step=-1, **changed):
        requests, views = replays[history]
        mutated = views.copy()
        mutated[step] = {**mutated[step], **changed}
        tests.append(verdict_test(name, requests, mutated))
        return name

    imported = replays['freshImportedReferencesTest'][1][-1]
    local = replays['freshLocalReferencesTest'][1][-1]
    refresh_name = 'movedPolicyRefreshReferencesTest'
    refresh_requests, _ = replays[refresh_name]
    _, stale_reply, _ = [index for index, request in enumerate(refresh_requests) if request['op'] == 'references']
    other_use = {'file': 'second.qnt', 'line': 3, 'column': 19}
    controls = [
        control('sameNamedLocalReferencesRejectedTest', 'freshImportedReferencesTest', references=local['references']),
        control('otherCallerReferenceRejectedTest', 'openOtherCallerDoesNotBroadenReferencesTest',
                references=[*imported['references'], other_use]),
        control('staleImportedReferencesRequestRejectedTest', 'movedPolicyRefusesImportedReferencesTest',
                lookups=imported['lookups']),
        control('oldServerReferencesListRejectedTest', refresh_name, step=stale_reply, **imported),
    ]
    verdicts = directory / 'graph_import_references_verdicts.qnt'
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
        with tempfile.TemporaryDirectory(prefix='qmodel-import-references-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint imported references replay: {error}\n')


if __name__ == '__main__':
    main()
