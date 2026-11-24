"""Replay a transitive Quint re-export against Neovim and the upstream server."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from replay_support import (ROOT, check_rejection, check_verdicts, observe, quint_test,
                            read_requests, verdict_test)

SPEC = ROOT / 'spec/graph_import_chain.qnt'
FIXTURE = ROOT / 'tests/fixtures/graph_import_chain'
HISTORIES = {f'{prefix}{method}{suffix}Test'
             for prefix, suffix in [('freshImported', ''), ('diskWrapper', 'Recovery'),
                                    ('dirtyWrapperRefuses', ''), ('changedWrapperAllowsLocal', '')]
             for method in ('Definition', 'Hover', 'References')}


def replay(directory, worktree):
    spec = directory / SPEC.name
    shutil.copyfile(SPEC, spec)
    histories = quint_test(spec, directory / 'histories')
    if missing := HISTORIES - histories.keys():
        raise ValueError(f'Missing Quint histories: {", ".join(sorted(missing))}')

    tests = ['module graph_import_chain_verdicts {',
             '  import graph_import_chain.* from "./graph_import_chain"']
    names, replays = set(), {}
    for history, path in histories.items():
        requests = read_requests(path)
        case = directory / history
        shutil.copytree(FIXTURE, case)
        observations = observe(history, requests, case, case / 'caller.qnt', worktree,
                               'replay_graph_import_chain.lua')
        replays[history] = requests, observations
        name = 'observed' + history[0].upper() + history[1:]
        tests.append(verdict_test(name, requests, observations))
        names.add(name)

    def control(name, history, method, occurrence, **changed):
        requests, views = replays[history]
        steps = [step for step, request in enumerate(requests) if request['op'] == method]
        step = steps[occurrence]
        mutated = views.copy()
        mutated[step] = {**mutated[step], **changed}
        tests.append(verdict_test(name, requests, mutated))
        return name

    fresh_definition_requests, fresh_definition_views = replays['freshImportedDefinitionTest']
    definition = next(view for request, view in zip(fresh_definition_requests, fresh_definition_views, strict=True)
                      if request['op'] == 'definition')
    hover = replays['freshImportedHoverTest'][1][-1]
    references = replays['freshImportedReferencesTest'][1][-1]
    controls = [
        control('diskWrapperLookupRejectedTest', 'diskWrapperDefinitionRecoveryTest', 'definition', 0,
                lookups=definition['lookups']),
        control('dirtyWrapperLookupRejectedTest', 'dirtyWrapperRefusesHoverTest', 'hover', 0,
                lookups=hover['lookups']),
        control('originalPolicyHoverRejectedTest', 'diskWrapperHoverRecoveryTest', 'hover', 1,
                hover=hover['hover']),
        control('originalPolicyReferencesRejectedTest', 'diskWrapperReferencesRecoveryTest', 'references', 1,
                references=references['references']),
    ]
    verdicts = directory / 'graph_import_chain_verdicts.qnt'
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
        with tempfile.TemporaryDirectory(prefix='qmodel-import-chain-replay-') as work:
            replay(Path(work).resolve(), args.worktree)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Quint import chain replay: {error}\n')


if __name__ == '__main__':
    main()
