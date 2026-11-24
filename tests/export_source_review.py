"""Check that source projections use exact byte positions and generic record handling."""

from hashlib import sha256
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def export(directory, text):
    directory.mkdir()
    source = directory / 'approval.qnt'
    output = directory / 'review.qmodel.json'
    source.write_bytes(text.replace('\n', '\r\n').encode('utf-8'))
    subprocess.run([sys.executable, '-B', str(ROOT / 'tools/export_model.py'), '--source-review',
                    str(source), 'review', 'mayApprove', '-o', str(output)], check=True, timeout=60)
    return json.loads(output.read_text(encoding='utf-8'))


def uses_at(model, text, anchor, name):
    [(row, line)] = [(row, line) for row, line in enumerate(text.splitlines(), 1) if anchor in line]
    column = len(line[:line.index(name)].encode('utf-8'))
    return [model['symbols'][use['target']] for use in model['uses'].values()
            if use.get('position') == {'line': row, 'column': column}]


if __name__ == '__main__':
    work = Path(sys.argv[1])
    text = (ROOT / 'examples/approval.qnt').read_text(encoding='utf-8')
    text = text.replace('if (allowed)', 'if (/* é😀 */ allowed)')
    original = export(work / 'State', text)
    renamed = export(work / 'Context', text.replace('State', 'Context'))
    assert original['graphs'] == renamed['graphs'] and original['uses'] == renamed['uses'], (
        'the source graph or uses depend on the record type being named State')
    [receiver] = uses_at(original, text, 'state.pending and', 'state')
    assert (receiver['name'], receiver['kind']) == ('state', 'parameter'), receiver
    [guard] = uses_at(original, text, '/* é😀 */ allowed', 'allowed')
    assert (guard['name'], guard['kind']) == ('allowed', 'local value'), guard
    print('Source-review positions and record neutrality passed.')

    source = ROOT / 'tests/fixtures/graph_import/caller.qnt'
    for label, flags in [('offline', []), ('review', ['--source-review'])]:
        output = work / f'import-{label}.qmodel.json'
        subprocess.run([sys.executable, '-B', str(ROOT / 'tools/export_model.py'), *flags,
                        str(source), 'review', '-o', str(output)], check=True, timeout=60)
        model = json.loads(output.read_text(encoding='utf-8'))
        guard = model['graphs'][0]['tree']['guard']
        assert ''.join(part['text'] for part in guard) == 'remote::allowed(ok)', guard
        links = [part for part in guard if 'position' in part]
        target_hash = sha256(source.with_name('policy.qnt').read_bytes()).hexdigest()
        expected = [{
            'text': 'remote::allowed', 'position': {'line': 6, 'column': 8},
            'definition_target': {'path': 'policy.qnt', 'line': 2, 'sha256': target_hash},
        }] if flags else []
        assert links == expected, links
        # Both modes keep their inspector index self-contained.
        assert all(use['target'] in model['symbols'] for use in model['uses'].values())
    print('Imported occurrences and their destination fingerprints are source-review only.')
