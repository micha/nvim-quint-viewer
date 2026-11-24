"""Replay the source graph's native branch-folding histories in Neovim."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/branch_folding.qnt'
FIXTURE = ROOT / 'tests/fixtures/branch_folding.qnt'
HISTORIES = {'siblingFoldsTest', 'nestedFoldsTest', 'deepFoldContainsBodyTest'}
CONTROL = 'extraFoldRejectedTest'


def deep_fixture():
    expression = '99'
    for depth in range(21, 0, -1):
        expression = f'if (guard) {{ {expression} }} else {depth}'
    return f'module branch_folding {{\n  pure def deep(guard: bool): int = {expression}\n}}\n'


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module branch_folding_verdicts {', '  import branch_folding.* from "./branch_folding"']
    names = set()
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        case.mkdir()
        source = case / FIXTURE.name
        if history == 'deepFoldContainsBodyTest':
            source.write_text(deep_fixture(), encoding='utf-8')
        else:
            shutil.copyfile(FIXTURE, source)
        observations = observe(history, requests, case, source, worktree, 'replay_branch_folding.lua')
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

        if history == 'siblingFoldsTest':
            # Substitute the real view with both branches closed for the view
            # just after closing Yes, when No should still be open.
            only_yes = requests.index({'op': 'close', 'arg': 'outerYes'})
            both = requests.index({'op': 'toggle', 'arg': 'outerNo'})
            wrong = [*observations[:only_yes], observations[both], *observations[only_yes + 1:]]
            tests.append(verdict_test(CONTROL, requests, wrong))

    verdicts = directory / 'branch_folding_verdicts.qnt'
    verdicts.write_text('\n\n'.join(tests) + '\n}\n', encoding='utf-8')
    check_verdicts(verdicts, directory / 'verdicts', names)
    check_rejection(verdicts, CONTROL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', action='store_true', help='load the plugin from the checkout instead of Git HEAD')
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix='qmodel-fold-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint branch folding replay: {error}\n')


if __name__ == '__main__':
    main()
