"""Replay graph hover and references against Neovim and the upstream Quint language server."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_lookups.qnt'
HISTORIES = {'freshHoverTest', 'freshReferencesTest', 'dirtyHoverTest', 'dirtyReferencesTest',
             'changedDiskHoverTest', 'changedDiskReferencesTest', 'unlinkedHoverTest', 'unlinkedReferencesTest'}


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module graph_lookup_verdicts {', '  import graph_lookups.* from "./graph_lookups"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        case.mkdir()
        source = case / 'approval.qnt'
        shutil.copyfile(ROOT / 'examples/approval.qnt', source)
        observations = observe(history, requests, case, source, worktree, 'replay_graph_lookups.lua')
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    def control(name, history, **changed):
        requests, views = replays[history]
        tests.append(verdict_test(name, requests, [*views[:-1], {**views[-1], **changed}]))
        return name

    hover = replays['freshHoverTest'][1][-1]
    references = replays['freshReferencesTest'][1][-1]
    wrong_origin = [{**query, 'position': {**query['position'], 'line': 8}} for query in hover['lookups']]
    # A lookup at the declaration could yield the same hover text; compare the
    # actual occurrence separately. Keep the warning in the stale control.
    controls = [
        control('wrongHoverOriginRejectedTest', 'freshHoverTest', lookups=wrong_origin),
        control('staleReferencesRequestRejectedTest', 'changedDiskReferencesTest', lookups=references['lookups']),
        control('missingReferenceRejectedTest', 'freshReferencesTest', references=references['references'][:-1]),
    ]
    verdicts = directory / 'graph_lookup_verdicts.qnt'
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
        with tempfile.TemporaryDirectory(prefix='qmodel-lookup-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint graph lookup replay: {error}\n')


if __name__ == '__main__':
    main()
