"""Replay graph and raw definition keys with the upstream Quint server."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_definition_mode.qnt'
FIXTURE = ROOT / 'tests/fixtures/graph_definition_mode'
HISTORIES = {
    'localGraphAndHistoryTest', 'importedGraphAndHistoryTest', 'importedGraphSupportsSecondHopTest',
    'parameterAdvisesRawAndJumpsTest', 'bindingAdvisesRawAndJumpsTest', 'rawSourceMapStillWorksTest',
    'importedRawDefinitionTest',
    'staleGraphBeforeRequestTest', 'staleCallerBeforeReplyTest', 'stalePolicyBeforeReplyTest',
    'stalePolicyBeforeRawReplyTest', 'stalePolicyDoesNotAffectLocalGraphTest', 'wrongScopeReplyTest',
}


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module graph_definition_mode_verdicts {',
             '  import graph_definition_mode.* from "./graph_definition_mode"']
    replays, names = {}, set()
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        shutil.copytree(FIXTURE, case)
        views = observe(history, requests, case, case / 'caller.qnt', worktree,
                        'replay_graph_definition_mode.lua')
        replays[history] = requests, views
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, views))
        names.add(name)

    def at_step(requests, op, occurrence=0):
        return [step for step, request in enumerate(requests) if request['op'] == op][occurrence]

    def observed(history, op='deliverReply'):
        requests, views = replays[history]
        return views[at_step(requests, op)]

    def control(name, history, op, occurrence=0, **changed):
        requests, views = replays[history]
        step = at_step(requests, op, occurrence)
        mutated = views.copy()
        mutated[step] = {**mutated[step], **changed}
        tests.append(verdict_test(name, requests, mutated))
        return name

    imported = 'importedGraphAndHistoryTest'
    chain = 'importedGraphSupportsSecondHopTest'
    controls = [
        control('rawFallbackRejectedTest', imported, 'deliverReply', **observed('importedRawDefinitionTest')),
        control('sameNamedLocalGraphRejectedTest', imported, 'deliverReply', **observed('localGraphAndHistoryTest')),
        control('wrongRedoBufferRejectedTest', imported, 'forward', atTarget=False),
        control('wrongSecondBackingSourceRejectedTest', chain, 'pressDefinition', occurrence=1,
                lookups=observed(chain, 'pressDefinition')['lookups']),
        control('staleReplyGraphRejectedTest', 'stalePolicyBeforeReplyTest', 'deliverReply',
                **{key: value for key, value in observed(imported).items() if key != 'notices'}),
    ]
    verdicts = directory / 'graph_definition_mode_verdicts.qnt'
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
        with tempfile.TemporaryDirectory(prefix='qmodel-definition-mode-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint definition mode replay: {error}\n')


if __name__ == '__main__':
    main()
