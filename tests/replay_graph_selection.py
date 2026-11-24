"""Replay source graph selection in Neovim."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_selection.qnt'
FIXTURE = ROOT / 'tests/fixtures/graph_selection.qnt'
HISTORIES = {
    'definitionNameTest', 'sameLineAfterUnicodeTest', 'nestedLocalTest',
    'moduleHeaderTest', 'outsideDefinitionTest', 'variantTest', 'declarationOnlyFileTest', 'destructuringAsSourceTest',
    'dirtySourceToggleAndRebuildTest', 'namedDefinitionsInOrderTest', 'namedDefinitionInSecondModuleTest',
    'ambiguousNamedModuleTest', 'nameDoesNotCrossModulesTest', 'soleModuleFallbackTest',
    'filenameFallbackTest', 'cursorModuleBeatsFilenameTest', 'namedDefinitionInMacFileTest',
}


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if histories.keys() != HISTORIES:
        raise ValueError(f'Expected the selection histories, got {sorted(histories)}')
    tests = ['module graph_selection_verdicts {', '  import graph_selection.* from "./graph_selection"']
    names, replays = set(), {}
    for history, trace in histories.items():
        requests = read_requests(trace)
        case = directory / history
        case.mkdir()
        filename_matches = history in {'filenameFallbackTest', 'cursorModuleBeatsFilenameTest'}
        use_mac = history == 'namedDefinitionInMacFileTest'
        source = case / ('First.qnt' if filename_matches else FIXTURE.name)
        if history == 'soleModuleFallbackTest':
            source.write_text('// Before the only module\nmodule Only { pure val decide = 1 }\n', encoding='utf-8')
        elif history == 'declarationOnlyFileTest':
            source.write_text('module Only {\n  type Choice = | Some(int) | None\n}\n', encoding='utf-8')
        elif history == 'destructuringAsSourceTest':
            source.write_text('module Pattern {\n  pure val (left, right) = (1, 2)\n'
                              '  pure val total = { val (a, b) = (left, right); a + b }\n}\n', encoding='utf-8')
        else:
            # Neovim strips line endings; Quint indexes the saved text. The
            # Quint lexer needs LF to terminate the fixture's line comment.
            text = FIXTURE.read_bytes()
            if use_mac:
                text = b'\n' + text.split(b'\n', 1)[1]
            source.write_bytes(text.replace(b'\n', b'\r' if use_mac else b'\r\n'))
        views = observe(history, requests, case, source, worktree, 'replay_graph_selection.lua',
                        QMODEL_MAC='1' if use_mac else '')
        replays[history] = requests, views
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, views))
        names.add(name)

    def control(name, history, step, **changed):
        requests, views = replays[history]
        mutated = views.copy()
        mutated[step] = {**views[step], **changed}
        tests.append(verdict_test(name, requests, mutated))
        return name

    controls = [
        control('missingModuleRejectedTest', 'outsideDefinitionTest', 1,
                definitions=['First:same', 'First:other', 'First:after']),
        control('wrongToggleCursorRejectedTest', 'sameLineAfterUnicodeTest', -1, position='other'),
    ]
    verdicts = directory / 'graph_selection_verdicts.qnt'
    verdicts.write_text('\n\n'.join(tests) + '\n}\n', encoding='utf-8')
    check_verdicts(verdicts, directory / 'verdicts', names)
    for name in controls:
        check_rejection(verdicts, name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', action='store_true', help='load the plugin from the checkout instead of Git HEAD')
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix='qmodel-selection-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint graph selection replay: {error}\n')


if __name__ == '__main__':
    main()
