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


NO_DEFINITION = 'no operator or value under the cursor; place it on a definition name or body'


def cursor_index(raw, offset):
    if not 0 <= offset <= len(raw):
        raise ValueError('cursor is outside the saved Quint source')
    # Quint indexes Unicode code points; the editor supplies a byte offset.
    return len(raw[:offset].decode('utf-8'))


def select_module(modules, offsets, module_name, stem, cursor, names):
    def contains(node):
        _, start, end = offsets[str(node['id'])]
        return cursor is not None and start['index'] <= cursor <= end['index']

    if module_name is not None:
        candidates = [module for module in modules if module['name'] == module_name]
        if len(candidates) != 1:
            raise ValueError(f'expected one module named {module_name!r} in the input file')
    else:
        candidates = [module for module in modules if contains(module)]
        if not candidates and names:
            candidates = modules if len(modules) == 1 else [m for m in modules if m['name'] == stem]
        if len(candidates) != 1:
            raise ValueError('place the cursor in a Quint module to select named definitions' if names else NO_DEFINITION)
    return candidates[0]


def select_at_cursor(definitions, offsets, cursor, declaration_only=False):
    no_match = ('no top-level operator or value starts at the declaration position'
                if declaration_only else NO_DEFINITION)
    # The compiler also emits `def`s for variant constructors. Cursor selection
    # should not mistake the text of a type declaration for an operator body.
    for node in definitions.values():
        if node['kind'] == 'typedef':
            _, start, end = offsets[str(node['id'])]
            if start['index'] <= cursor <= end['index']:
                raise ValueError(no_match)
    names = []
    for name, node in definitions.items():
        if node['kind'] != 'def':
            continue
        # A definition's ID maps to its name, not its whole declaration. The
        # expression span supplies the other bound (including nested bindings).
        start = offsets[str(node['id'])][1]['index']
        end = start if declaration_only else offsets[str(node['expr']['id'])][2]['index']
        if start <= cursor <= end:
            names.append(name)
    if len(names) != 1:
        raise ValueError(no_match)
    return names


def load_ir(quint, source, module_name, raw, cursor, names, declaration_only):
    with TemporaryDirectory() as tmp:
        ir = Path(tmp) / 'model.json'
        locations = Path(tmp) / 'locations.json'

        def parse():
            subprocess.run([quint, 'parse', str(source), '--out', str(ir), '--source-map', str(locations)],
                           check=True)
            parsed = json.loads(ir.read_text())
            if parsed.get('errors'):
                raise ValueError(f'Quint parse failed: {parsed["errors"]}')
            return parsed, json.loads(locations.read_text())

        parsed, index = parse()
        files = {Path(path) for path in index['sourceIndex'].values()}
        contents = {path: raw if path == source else path.read_bytes() for path in files}
        fingerprints = {path: sha256(data).hexdigest() for path, data in contents.items()}
        if files - {source}:
            # The first parse discovers imports. Parse again after capturing
            # their fingerprints so an old map isn't paired with new bytes.
            parsed, index = parse()
            if {Path(path) for path in index['sourceIndex'].values()} != files:
                raise ValueError('Quint imports changed while building the graph; run :QuintView again')

        source_ids = {int(key) for key, path in index['sourceIndex'].items() if Path(path).resolve() == source}
        offsets = {key: span for key, span in index['map'].items() if span[0] in source_ids}
        modules = [module for module in parsed['modules'] if str(module['id']) in offsets]
        module = select_module(modules, offsets, module_name, source.stem, cursor, names)
        definitions = {node['name']: node for node in module['declarations'] if 'name' in node}
        if any(str(node['id']) not in offsets for node in definitions.values()):
            raise ValueError('selected module must be defined in the input file')
        if not names:
            names = select_at_cursor(definitions, offsets, cursor, declaration_only)
        subprocess.run([quint, 'typecheck', str(source), '--out', str(ir)], check=True)
        checked = json.loads(ir.read_text())
        if checked.get('errors'):
            raise ValueError(f'Quint typecheck failed: {checked["errors"]}')
        for path, fingerprint in fingerprints.items():
            if sha256(path.read_bytes()).hexdigest() != fingerprint:
                raise ValueError('Quint source changed while building the graph; run :QuintView again')
        targets = review_targets(parsed, index, source, contents)
        # A binding points at its final declaration, not every re-export on
        # the way there. Retain the whole external input set reported by Quint.
        imports = {relpath(path, source.parent): fingerprint
                   for path, fingerprint in fingerprints.items() if path != source}
        return module['name'], names, definitions, offsets, checked, targets, imports


def source_definition_ids(modules, spans):
    ids = set()
    for module in modules:
        declarations = module['declarations']
        typedefs = [spans[str(node['id'])] for node in declarations
                    if node['kind'] == 'typedef' and str(node['id']) in spans]
        for node in declarations:
            span = spans.get(str(node['id']))
            if node['kind'] != 'def' or not span:
                continue
            file_id, start, _ = span
            # Synthetic variant constructors are not standalone source definitions.
            if not any(file_id == file and begin['index'] <= start['index'] <= end['index']
                       for file, begin, end in typedefs):
                ids.add(node['id'])
    return ids


def review_targets(parsed, index, source, contents):
    lines = {file: raw.decode('utf-8').split('\n') for file, raw in contents.items()}
    renderable = source_definition_ids(parsed['modules'], index['map'])
    targets = {}
    for use, binding in parsed['table'].items():
        span = index['map'].get(str(binding['id']))
        if use in index['map'] and span:
            file_id, start, _ = span
            file = Path(index['sourceIndex'][str(file_id)])
            line = lines[file][start['line']]
            column = len(line[:start['col']].encode('utf-8'))
            targets[use] = dict(path=relpath(file, source.parent), line=start['line'] + 1, column=column,
                                renderable=binding['id'] in renderable)
    return targets


class Exporter:
    def __init__(self, definitions, index):
        self.definitions = definitions
        self.index = index

    def fragments(self, node):
        start, end = self.index.span(node)
        return [{**part, 'text': re.sub(r'\r?\n[ \t]*', ' ', part['text'])}
                for part in self.index.fragments(start, end) if part['text']]

    def tree(self, node):
        bindings = []
        while node['kind'] == 'let':
            local = node['opdef']
            bindings.append(dict(name=local['name'], expr=self.fragments(local['expr'])))
            node = node['expr']
        data = dict(bindings=bindings)
        if node.get('opcode') == 'ite':
            guard, yes, no = node['args']
            return dict(data, guard=self.fragments(guard), yes=self.tree(yes), no=self.tree(no))
        return dict(data, expression=self.fragments(node))

    def graph(self, name):
        definition = self.definitions.get(name)
        if not definition or definition['kind'] != 'def':
            raise ValueError(f'no operator or value named {name!r} in the selected module')
        node = definition['expr']
        if node['kind'] == 'lambda':
            node = node['expr']
        return dict(title=name, tree=self.tree(node))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('definitions', nargs='*', help='operators or values to visualize, in display order')
    parser.add_argument('-o', '--output', required=True, type=Path)
    parser.add_argument('--module', help='explicit module in the source file')
    parser.add_argument('--cursor', type=int, metavar='BYTE_OFFSET',
                        help='zero-based byte offset in the saved source')
    parser.add_argument('--quint', default='quint', help='Quint CLI executable')
    parser.add_argument('--declaration', action='store_true',
                        help='require the cursor to be at a top-level definition name start')
    args = parser.parse_args()
    if args.declaration and (args.definitions or args.cursor is None):
        parser.error('--declaration requires a cursor position and no definition names')
    if not args.definitions and args.cursor is None:
        parser.error('provide definition names or a cursor position')
    source = args.source.resolve()
    try:
        raw = source.read_bytes()
        text = raw.decode('utf-8')
        cursor = cursor_index(raw, args.cursor) if args.cursor is not None else None
        module, names, definitions, offsets, checked, definition_targets, imports = load_ir(
            args.quint, source, args.module, raw, cursor, args.definitions, args.declaration)
        index = Index(definitions, offsets, text, checked['table'], definition_targets)
        exporter = Exporter(definitions, index)
        model = {
            'format': 'quint-decision-model', 'version': 5, 'module': module,
            'source': {'sha256': sha256(raw).hexdigest()}, 'imports': imports,
            'graphs': [exporter.graph(name) for name in names],
        }
        args.output.write_text(json.dumps(model, ensure_ascii=False, sort_keys=True) + '\n', encoding='utf-8')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'quint model export: {error}\n')


if __name__ == '__main__':
    main()
