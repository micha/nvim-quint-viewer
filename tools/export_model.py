#!/usr/bin/env python3
"""Export selected Quint definitions as a deterministic decision model."""

import argparse
from hashlib import sha256
import json
from os.path import relpath
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory

from symbol_index import Index


def load_ir(quint, source, module_name):
    with TemporaryDirectory() as tmp:
        ir = Path(tmp) / 'model.json'
        locations = Path(tmp) / 'locations.json'
        subprocess.run([quint, 'parse', str(source), '--out', str(ir), '--source-map', str(locations)],
                       check=True)
        parsed = json.loads(ir.read_text())
        if parsed.get('errors'):
            raise ValueError(f'Quint parse failed: {parsed["errors"]}')
        modules = [module for module in parsed['modules'] if module['name'] == module_name]
        if len(modules) != 1:
            raise ValueError(f'expected one module named {module_name!r}; use --module to select it')
        index = json.loads(locations.read_text())
        source_ids = {int(key) for key, path in index['sourceIndex'].items() if Path(path).resolve() == source}
        offsets = {key: span for key, span in index['map'].items() if span[0] in source_ids}
        definitions = {node['name']: node for node in modules[0]['declarations'] if 'name' in node}
        if any(str(node['id']) not in offsets for node in definitions.values()):
            raise ValueError('selected module must be defined in the input file')
        subprocess.run([quint, 'typecheck', str(source), '--out', str(ir)], check=True)
        checked = json.loads(ir.read_text())
        if checked.get('errors'):
            raise ValueError(f'Quint typecheck failed: {checked["errors"]}')
        return definitions, offsets, checked


class Exporter:
    def __init__(self, definitions, index, profile):
        self.definitions = definitions
        self.index = index
        self.profile = profile

    def fragments(self, node):
        start, end, _ = self.index.span(node)
        return [{**part, 'text': re.sub(r'\r?\n[ \t]*', ' ', part['text'])}
                for part in self.index.fragments(start, end) if part['text']]

    def state_updates(self, node, locals_):
        if node.get('opcode') == 'with':
            base, field, value = node['args']
            updates = self.state_updates(base, locals_)
            if updates is not None and field['kind'] == 'str':
                return {**updates, field['value']: (field, value)}
        if node['kind'] == 'name':
            if node['name'] == 'state':
                return {}
            resolved = self.index.table.get(str(node['id']), {})
            if resolved.get('id') in locals_:
                expression, scope = locals_[resolved['id']]
                return self.state_updates(expression, scope)
        return None

    def prediction(self, node):
        if not self.profile:
            return None
        name = node.get('opcode')
        if name not in ('predict', 'unsupported', 'success'):
            return None
        target = self.index.table.get(str(node['id']), {})
        if target.get('id') != self.definitions.get(name, {}).get('id'):
            return None
        if name == 'predict':
            return node['args']
        body = self.definitions[name]['expr']['expr']
        if body.get('opcode') != 'predict' or len(body['args']) != 5:
            raise ValueError(f'dml-refs profile expects {name} to wrap predict')
        _, status, value, count, label = body['args']
        state, *labels = node['args']
        if labels:
            label, = labels
        return state, status, value, count, label

    def outcome(self, node, locals_, data):
        predicted = self.prediction(node)
        if predicted is None:
            return dict(data, expression=self.fragments(node))
        state, status, value, count, label = predicted
        if node.get('opcode') == 'unsupported':
            return dict(data, unsupported=self.fragments(label))
        outcome = dict(status=self.fragments(status), label=self.fragments(label),
                       value=self.fragments(value), count=self.fragments(count))
        updates = self.state_updates(state, locals_)
        if updates is None:
            return dict(data, outcome=dict(outcome, next_state=self.fragments(state)))
        outcome['updates'] = []
        for field, expression in updates.values():
            if expression.get('opcode') == 'Map' and not expression['args']:
                value = [{'text': 'empty map'}]
            elif expression.get('opcode') == 'field' and expression['args'][0].get('name') == 'state':
                value = [{'text': 'previous '}, self.index.field_fragment(expression['args'][1])]
            else:
                value = self.fragments(expression)
            outcome['updates'].append(dict(field=self.index.field_fragment(field), value=value))
        return dict(data, outcome=outcome)

    def tree(self, node, locals_):
        bindings = []
        while node['kind'] == 'let':
            local = node['opdef']
            if self.profile and local['name'] == 'closed' and self.state_updates(local['expr'], locals_) is not None:
                locals_ = {**locals_, local['id']: (local['expr'], locals_)}
            else:
                bindings.append(dict(name=local['name'], symbol=str(local['id']), expr=self.fragments(local['expr'])))
            node = node['expr']
        data = dict(bindings=bindings)
        if node.get('opcode') == 'ite':
            guard, yes, no = node['args']
            return dict(data, guard=self.fragments(guard), yes=self.tree(yes, locals_), no=self.tree(no, locals_))
        return self.outcome(node, locals_, data)

    def graph(self, name):
        definition = self.definitions.get(name)
        if not definition or definition['kind'] != 'def':
            raise ValueError(f'no operator or value named {name!r} in the selected module')
        node = definition['expr']
        if node['kind'] == 'lambda':
            node = node['expr']
        return dict(id=name, title=name, tree=self.tree(node, {}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('definitions', nargs='+', help='operators or values to visualize, in display order')
    parser.add_argument('-o', '--output', required=True, type=Path)
    parser.add_argument('--module', help='module name (defaults to the source filename stem)')
    parser.add_argument('--quint', default='quint', help='Quint CLI executable')
    parser.add_argument('--profile', choices=['dml-refs'], help='enable domain-specific outcome formatting')
    args = parser.parse_args()
    if not args.output.name.endswith('.qmodel.json'):
        parser.error('output filename must end in .qmodel.json')
    source = args.source.resolve()
    module = args.module or source.stem
    try:
        raw = source.read_bytes()
        text = raw.decode('utf-8')
        definitions, offsets, checked = load_ir(args.quint, source, module)
        index = Index(definitions, offsets, text, checked)
        exporter = Exporter(definitions, index, args.profile)
        output = args.output.resolve()
        artifact = {
            'format': 'quint-decision-model', 'version': 1, 'module': module,
            'source': {'path': relpath(source, output.parent), 'sha256': sha256(raw).hexdigest()},
            'graphs': [exporter.graph(name) for name in args.definitions],
            **index.payload(),
        }
        output.write_text(json.dumps(artifact, ensure_ascii=False, sort_keys=True) + '\n', encoding='utf-8')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'quint model export: {error}\n')


if __name__ == '__main__':
    main()
