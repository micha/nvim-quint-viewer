"""Check that source projections use exact byte positions and generic record handling."""

from hashlib import sha256
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def export(source, output, *names, imports=None):
    subprocess.run([sys.executable, '-B', str(ROOT / 'tools/export_model.py'), '-o', str(output), '--',
                    str(source), *names], check=True, timeout=60)
    model = json.loads(output.read_bytes())
    assert set(model) == {'format', 'version', 'source', 'module', 'graphs', 'imports'}, model.keys()
    assert (model['format'], model['version']) == ('quint-decision-model', 5)
    assert model['source'] == {'sha256': sha256(source.read_bytes()).hexdigest()}
    assert model['imports'] == (imports or {}), model['imports']
    assert [graph['title'] for graph in model['graphs']] == list(names)
    return model


def export_text(directory, text):
    directory.mkdir()
    source = directory / 'approval.qnt'
    source.write_bytes(text.replace('\n', '\r\n').encode('utf-8'))
    return export(source, directory / 'review.json', 'review', 'mayApprove')


def fragments(node):
    for binding in node['bindings']:
        yield from binding['expr']
    if 'guard' in node:
        yield from node['guard']
        yield from fragments(node['yes'])
        yield from fragments(node['no'])
    else:
        yield from node['expression']


def check_local_occurrence(model, text, anchor, name):
    [(row, line)] = [(row, line) for row, line in enumerate(text.splitlines(), 1) if anchor in line]
    column = len(line[:line.index(name)].encode('utf-8'))
    matches = [part for graph in model['graphs'] for part in fragments(graph['tree'])
               if part.get('position') == {'line': row, 'column': column}]
    assert matches == [{'text': name, 'position': {'line': row, 'column': column}}], matches


if __name__ == '__main__':
    work = Path(sys.argv[1])
    text = (ROOT / 'examples/approval.qnt').read_text(encoding='utf-8')
    text = text.replace('if (allowed)', 'if (/* é😀 */ allowed)')
    original = export_text(work / 'State', text)
    renamed = export_text(work / 'Context', text.replace('State', 'Context'))
    assert original['graphs'] == renamed['graphs'], 'the source graph depends on a record named State'
    check_local_occurrence(original, text, 'state.pending and', 'state')
    check_local_occurrence(original, text, '/* é😀 */ allowed', 'allowed')
    print('Source graph positions and record neutrality passed.')

    source = ROOT / 'tests/fixtures/graph_import/caller.qnt'
    target_hash = sha256(source.with_name('policy.qnt').read_bytes()).hexdigest()
    model = export(source, work / 'import-projection.json', 'review', imports={'policy.qnt': target_hash})
    guard = model['graphs'][0]['tree']['guard']
    assert ''.join(part['text'] for part in guard) == 'remote::allowed(ok)', guard
    links = [part for part in guard if 'position' in part]
    assert links == [{
        'text': 'remote::allowed', 'position': {'line': 6, 'column': 8},
        'definition_target': {'path': 'policy.qnt', 'line': 2, 'column': 11,
                              'renderable': True, 'requires_imports': True},
    }, {'text': 'ok', 'position': {'line': 6, 'column': 24}}], links
    directory = work / 'unicode-import'
    directory.mkdir()
    caller = directory / 'caller.qnt'
    caller.write_bytes(source.read_bytes())
    policy = source.with_name('policy.qnt').read_text(encoding='utf-8')
    prefix = '  /* é😀 */ pure def '
    policy = policy.replace('  pure def allowed', prefix + 'allowed').replace('\n', '\r\n').encode('utf-8')
    caller.with_name('policy.qnt').write_bytes(policy)
    model = export(caller, work / 'unicode-import-projection.json', 'review',
                   imports={'policy.qnt': sha256(policy).hexdigest()})
    [target] = [part['definition_target'] for part in model['graphs'][0]['tree']['guard']
                if 'definition_target' in part]
    assert target == {'path': 'policy.qnt', 'line': 2, 'column': len(prefix.encode('utf-8')),
                      'renderable': True, 'requires_imports': True}, target
    print('Imported occurrences, destination byte positions and fingerprints passed.')

    fixture = ROOT / 'tests/fixtures/graph_import_chain'
    directory = work / 'import-chain'
    shutil.copytree(fixture, directory)
    imports = {name: sha256((fixture / name).read_bytes()).hexdigest() for name in ('policy.qnt', 'wrapper.qnt')}
    original = work / 'original-chain.json'
    relocated = work / 'relocated-chain.json'
    model = export(fixture / 'caller.qnt', original, 'review', imports=imports)
    export(directory / 'caller.qnt', relocated, 'review', imports=imports)
    assert original.read_bytes() == relocated.read_bytes(), 'projection depends on the checkout path'
    assert model['graphs'][0]['tree']['guard'][0]['definition_target'] == {
        'path': 'policy.qnt', 'line': 3, 'column': 11, 'renderable': True, 'requires_imports': True,
    }

    wrapper = directory / 'wrapper.qnt'
    wrapper.write_bytes(wrapper.read_bytes().replace(b'policy.*', b'alternatePolicy.*'))
    imports['wrapper.qnt'] = sha256(wrapper.read_bytes()).hexdigest()
    redirected = export(directory / 'caller.qnt', work / 'redirected-chain.json', 'review', imports=imports)
    assert redirected['source'] == model['source'], 'caller changed during wrapper redirect'
    assert redirected['graphs'][0]['tree']['guard'][0]['definition_target'] == {
        'path': 'policy.qnt', 'line': 9, 'column': 11, 'renderable': True, 'requires_imports': True,
    }
    print('Transitive import fingerprints and deterministic re-export anchors passed.')

    source = ROOT / 'tests/fixtures/graph_definition_mode/caller.qnt'
    policy_hash = sha256(source.with_name('policy.qnt').read_bytes()).hexdigest()
    model = export(source, work / 'jump-projection.json', 'review', imports={'policy.qnt': policy_hash})
    parts = list(fragments(model['graphs'][0]['tree']))
    assert [part['definition_target'] for part in parts if part.get('text') == 'allowed'] == [{
        'path': 'caller.qnt', 'line': 3, 'column': 11, 'renderable': True, 'requires_imports': False,
    }]
    for symbol in ('permitted', 'input'):
        uses = [part for part in parts if part.get('text') == symbol]
        assert uses and all('position' in part and 'definition_target' not in part for part in uses), uses

    raw = source.read_bytes()
    output = work / 'declaration.json'
    local_name = raw.index(b'allowed(ok')
    command = [sys.executable, '-B', str(ROOT / 'tools/export_model.py'), '-o', str(output), '--declaration']
    subprocess.run([*command, '--cursor', str(local_name), '--', str(source)], check=True, timeout=60)
    opened = json.loads(output.read_bytes())
    assert opened['module'] == 'caller' and [g['title'] for g in opened['graphs']] == ['allowed']
    output.unlink()
    for point in (local_name + 1, raw.index(b'permitted ='), raw.index(b'input: bool')):
        result = subprocess.run([*command, '--cursor', str(point), '--', str(source)],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode != 0 and 'no top-level operator or value starts' in result.stderr, result.stderr
        assert not output.exists()
    print('Scoped graph jump anchors and exact declaration selection passed.')
