"""Check that source projections use exact byte positions and generic record handling."""

from hashlib import sha256
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def export_command(source, output, *names, options=()):
    return [sys.executable, '-B', str(ROOT / 'tools/export_model.py'), '-o', str(output),
            *options, '--', str(source), *names]


def graphs(model):
    [module] = model['modules']
    return module['graphs']


def export(source, output, *names, imports=None, options=()):
    subprocess.run(export_command(source, output, *names, options=options), check=True, timeout=60)
    model = json.loads(output.read_bytes())
    assert set(model) == {'format', 'version', 'source', 'imports', 'modules'}, model.keys()
    assert (model['format'], model['version']) == ('quint-decision-model', 6)
    assert model['source'] == {'sha256': sha256(source.read_bytes()).hexdigest()}
    assert model['imports'] == (imports or {}), model['imports']
    assert model['modules'] and all(set(module) == {'name', 'graphs'} and module['graphs'] for module in model['modules'])
    if names:
        assert [graph['title'] for graph in graphs(model)] == list(names)
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
    matches = [part for graph in graphs(model) for part in fragments(graph['tree'])
               if part.get('position') == {'line': row, 'column': column}]
    assert matches == [{'text': name, 'position': {'line': row, 'column': column}}], matches


if __name__ == '__main__':
    work = Path(sys.argv[1])
    text = (ROOT / 'examples/approval.qnt').read_text(encoding='utf-8')
    text = text.replace('if (allowed)', 'if (/* é😀 */ allowed)')
    original = export_text(work / 'State', text)
    renamed = export_text(work / 'Context', text.replace('State', 'Context'))
    assert graphs(original) == graphs(renamed), 'the source graph depends on a record named State'
    check_local_occurrence(original, text, 'state.pending and', 'state')
    check_local_occurrence(original, text, '/* é😀 */ allowed', 'allowed')
    print('Source graph positions and record neutrality passed.')

    source = ROOT / 'tests/fixtures/graph_import/caller.qnt'
    target_hash = sha256(source.with_name('policy.qnt').read_bytes()).hexdigest()
    model = export(source, work / 'import-projection.json', 'review', imports={'policy.qnt': target_hash})
    guard = graphs(model)[0]['tree']['guard']
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
    [target] = [part['definition_target'] for part in graphs(model)[0]['tree']['guard']
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
    assert graphs(model)[0]['tree']['guard'][0]['definition_target'] == {
        'path': 'policy.qnt', 'line': 3, 'column': 11, 'renderable': True, 'requires_imports': True,
    }

    wrapper = directory / 'wrapper.qnt'
    wrapper.write_bytes(wrapper.read_bytes().replace(b'policy.*', b'alternatePolicy.*'))
    imports['wrapper.qnt'] = sha256(wrapper.read_bytes()).hexdigest()
    redirected = export(directory / 'caller.qnt', work / 'redirected-chain.json', 'review', imports=imports)
    assert redirected['source'] == model['source'], 'caller changed during wrapper redirect'
    assert graphs(redirected)[0]['tree']['guard'][0]['definition_target'] == {
        'path': 'policy.qnt', 'line': 9, 'column': 11, 'renderable': True, 'requires_imports': True,
    }
    print('Transitive import fingerprints and deterministic re-export anchors passed.')

    source = ROOT / 'tests/fixtures/graph_definition_mode/caller.qnt'
    policy_hash = sha256(source.with_name('policy.qnt').read_bytes()).hexdigest()
    model = export(source, work / 'jump-projection.json', 'review', imports={'policy.qnt': policy_hash})
    parts = list(fragments(graphs(model)[0]['tree']))
    assert [part['definition_target'] for part in parts if part.get('text') == 'allowed'] == [{
        'path': 'caller.qnt', 'line': 3, 'column': 11, 'renderable': True, 'requires_imports': False,
    }]
    for symbol in ('permitted', 'input'):
        uses = [part for part in parts if part.get('text') == symbol]
        assert uses and all('position' in part and 'definition_target' not in part for part in uses), uses

    raw = source.read_bytes()
    output = work / 'declaration.json'
    local_name = raw.index(b'allowed(ok')
    opened = export(source, output, imports={'policy.qnt': policy_hash},
                    options=('--declaration', '--cursor', str(local_name)))
    assert opened['modules'][0]['name'] == 'caller' and [g['title'] for g in graphs(opened)] == ['allowed']
    output.unlink()
    for point in (local_name + 1, raw.index(b'permitted ='), raw.index(b'input: bool')):
        result = subprocess.run(export_command(source, output, options=('--declaration', '--cursor', str(point))),
                                capture_output=True, text=True, timeout=60)
        assert result.returncode != 0 and 'no top-level operator or value starts' in result.stderr, result.stderr
        assert not output.exists()
    print('Scoped graph jump anchors and exact declaration selection passed.')

    directory = work / 'whole-file'
    directory.mkdir()
    source = directory / 'program.qnt'
    text = '''module ZFirst {
  import policy as remote from "./policy"
  pure val localValue = 1
  pure val same = "é😀" pure val other = remote::adjust(localValue)
  type Flag = | On | Off
}
module Empty {
  type Choice = | Some(int) | None
  var state: int
  const limit: int
}
module ASecond {
  import ZFirst as nearby
  pure val localValue = 9
  pure def same(flag: bool): int = {
    val inner = localValue + nearby::other
    if (flag) inner else 0
  }
}
'''
    source.write_text(text, encoding='utf-8')
    policy = source.with_name('policy.qnt')
    policy.write_text('module policy { pure def adjust(n: int): int = n + 1 }\n', encoding='utf-8')
    imports = {'policy.qnt': sha256(policy.read_bytes()).hexdigest()}
    output = directory / 'all.json'
    model = export(source, output, imports=imports)
    assert [(module['name'], [g['title'] for g in module['graphs']]) for module in model['modules']] == [
        ('ZFirst', ['localValue', 'same', 'other']), ('ASecond', ['localValue', 'same']),
    ], model['modules']
    first, second = model['modules']
    assert first['graphs'][1]['tree']['expression'] == [{'text': '"é😀"'}]
    [binding] = second['graphs'][1]['tree']['bindings']
    assert binding['name'] == 'inner'

    def link(parts, name):
        [part] = [part for part in parts if part['text'] == name and 'position' in part]
        return part

    expr = first['graphs'][2]['tree']['expression']
    local = link(expr, 'localValue')
    assert local['position'] == {'line': 4, 'column': len(text.splitlines()[3].split('localValue')[0].encode('utf-8'))}
    assert local['definition_target'] == {
        'path': 'program.qnt', 'line': 3, 'column': 11, 'renderable': True, 'requires_imports': False,
    }
    assert link(expr, 'remote::adjust')['definition_target'] == {
        'path': 'policy.qnt', 'line': 1, 'column': 25, 'renderable': True, 'requires_imports': True,
    }
    assert link(binding['expr'], 'localValue')['definition_target'] == {
        'path': 'program.qnt', 'line': 14, 'column': 11, 'renderable': True, 'requires_imports': False,
    }
    assert link(binding['expr'], 'nearby::other')['definition_target'] == {
        'path': 'program.qnt', 'line': 4, 'column': len('  pure val same = "é😀" pure val '.encode('utf-8')),
        'renderable': True, 'requires_imports': True,
    }

    duplicate = directory / 'duplicate.json'
    export(source, duplicate, imports=imports)
    assert output.read_bytes() == duplicate.read_bytes()
    same = source.read_bytes().index(b'same(flag')
    opened = export(source, directory / 'focused.json', imports=imports,
                    options=('--declaration', '--cursor', str(same)))
    assert opened['modules'] == [{'name': 'ASecond', 'graphs': [second['graphs'][1]]}]

    empty = directory / 'empty.qnt'
    empty.write_text('module Empty { type Choice = | Some(int) | None }\n', encoding='utf-8')
    empty_output = directory / 'empty.json'
    result = subprocess.run(export_command(empty, empty_output), capture_output=True, text=True, timeout=60)
    assert result.returncode != 0 and 'no top-level operators or values in this file' in result.stderr, result.stderr
    assert not empty_output.exists()
    print('Whole-file ordering, scoped source links, imports and declaration focus passed.')

    source = work / 'pattern.qnt'
    pattern_text = '''module Pattern {
  pure val quintDestructTempUser = 3
  pure val (left, right) = (1, quintDestructTempUser)
  pure val (_, _) = (4, 5)
  pure val {third, fourth} = {third: 6, fourth: 7}
  pure val total = {
    val keep = quintDestructTempUser
    val (a, b) = (left + keep, right)
    a + b + quintDestructTempUser + third
  }
}
'''
    source.write_text(pattern_text, encoding='utf-8')
    opened = export(source, work / 'pattern.json')
    user_value, pair, holes, record, total = graphs(opened)
    assert [graph['title'] for graph in graphs(opened)] == [
        'quintDestructTempUser', 'Destructuring', 'Destructuring', 'Destructuring', 'total',
    ]
    assert user_value['tree']['expression'] == [{'text': '3'}]
    for graph, line in ((pair, 3), (holes, 4), (record, 5)):
        assert graph['tree']['bindings'] == []
        assert ''.join(part['text'] for part in graph['tree']['expression']) == pattern_text.splitlines()[line - 1].strip()
    tree = total['tree']
    [binding] = tree['bindings']
    assert binding['name'] == 'keep'
    raw_let = 'val (a, b) = (left + keep, right) a + b + quintDestructTempUser + third'
    assert ''.join(part['text'] for part in tree['expression']) == raw_let
    user_target = {'path': 'pattern.qnt', 'line': 2, 'column': 11, 'renderable': True, 'requires_imports': False}
    for expr in (pair['tree']['expression'], binding['expr'], tree['expression']):
        assert link(expr, 'quintDestructTempUser')['definition_target'] == user_target
    assert link(tree['expression'], 'keep')['position'] == {'line': 8, 'column': 25}
    for symbol in ('a', 'b'):
        assert 'definition_target' not in link(tree['expression'], symbol)

    focused = export(source, work / 'pattern-focused.json', 'total')
    assert graphs(focused) == [total]
    unsupported = work / 'pattern-unsupported.json'
    for name in ('left', 'Destructuring'):
        result = subprocess.run(export_command(source, unsupported, name), capture_output=True, text=True, timeout=60)
        assert result.returncode != 0 and 'no operator or value named' in result.stderr, result.stderr
        assert not unsupported.exists()
    raw = source.read_bytes()
    for offset in (raw.index(b'pure val (left'), raw.index(b'left, right')):
        result = subprocess.run(export_command(source, unsupported, options=('--declaration', '--cursor', str(offset))),
                                capture_output=True, text=True, timeout=60)
        assert result.returncode != 0 and 'no top-level operator or value starts' in result.stderr, result.stderr
        assert not unsupported.exists()
    print('Destructuring source fallback and mapped links passed.')
