"""Build the symbol index for the offline decision-graph inspector."""

from bisect import bisect_right
import re


def type_text(node):
    kind = node['kind']
    if kind in ('const', 'var'):
        return node['name']
    if kind in ('str', 'int', 'bool'):
        return kind
    if kind in ('set', 'list'):
        return f'{kind.title()}[{type_text(node["elem"])}]'
    if kind == 'fun':
        return f'{type_text(node["arg"])} → {type_text(node["res"])}'
    if kind == 'oper':
        params = ', '.join(map(type_text, node['args']))
        return f'({params}) → {type_text(node["res"])}'
    if kind == 'rec':
        fields = node['fields'].get('fields', [])
        return '{ ' + ', '.join(f'{f["fieldName"]}: {type_text(f["fieldType"])}' for f in fields) + ' }'
    return kind


class Index:
    def __init__(self, defs, offsets, source, checked, *, state_fields=True):
        self.source = source
        self.offsets = offsets
        self.table = checked['table']
        self.types = checked['types']
        self.symbols = {}
        self.uses = {}
        self.tokens = {}
        state = defs.get('State', {}).get('type', {}) if state_fields else {}
        fields = state.get('fields', {}).get('fields', []) if state.get('kind') == 'rec' else []
        self.fields = {f['fieldName']: f['fieldType'] for f in fields}
        for name, field_type in self.fields.items():
            self.symbol(f'field-{name}', name, 'State field', field_type, field_type)
        for definition in defs.values():
            if definition['kind'] == 'def':
                self.visit_def(definition, local=False)

    def span(self, node):
        _, start, end = self.offsets[str(node['id'])]
        return start['index'], end['index'] + 1, start['line'] + 1

    def inferred(self, node):
        return self.types.get(str(node['id']), {}).get('type')

    def symbol(self, key, name, kind, node, annotation, expr=None):
        start, end, line = self.span(node)
        left = self.source.rfind('\n', 0, start) + 1
        right = self.source.find('\n', start)
        snippet = self.source[left:right if right != -1 else None].strip()
        if expr is not None and kind != 'function':
            a, b, _ = self.span(expr)
            snippet = self.source[a:b].strip()
            snippet = f'{name} = {snippet}'
        summary = f'{name}: {type_text(annotation)}' if annotation else 'Not available'
        self.symbols[key] = dict(name=name, kind=kind, line=line, snippet=snippet, type=summary)
        if node.get('name') == name:
            self.token(start, end, name, key)

    def token(self, start, end, spelling, target, use=None, tail=False):
        matches = list(re.finditer(rf'\b{re.escape(spelling)}\b', self.source[start:end]))
        if matches:
            match = matches[-1 if tail else 0]
            self.tokens[start + match.start()] = (start + match.end(), spelling, target, use)

    def use(self, node, spelled, target, owner, kind, tail=False):
        key = str(node['id'])
        start, end, line = self.span(node)
        left = self.source.rfind('\n', 0, start) + 1
        right = self.source.find('\n', start)
        snippet = self.source[left:right if right != -1 else None].strip()
        self.uses[key] = dict(target=target, owner=owner, kind=kind, line=line, snippet=snippet)
        self.token(start, end, spelled, target, key, tail)

    def is_state(self, node):
        if not self.fields:
            return False
        info = self.inferred(node)
        if not info:
            return False
        if info['kind'] == 'const':
            return info['name'] == 'State'
        if info['kind'] != 'rec':
            return False
        fields = {f['fieldName']: f['fieldType'] for f in info['fields'].get('fields', [])}
        # An update can expand State into a record and replace some field types.
        return fields.keys() == self.fields.keys() and any(
            fields[name].get('id') == expected['id'] for name, expected in self.fields.items()
        )

    def visit_def(self, node, local):
        key = str(node['id'])
        expr = node['expr']
        kind = 'local value' if local else 'value'
        if expr['kind'] == 'lambda':
            kind = 'function'
        self.symbol(key, node['name'], kind, node, node.get('typeAnnotation') or self.inferred(node), expr)
        if node.get('typeAnnotation', {}).get('name') == 'State' and expr.get('opcode') == 'Rec':
            for field in expr['args'][::2]:
                if field['value'] in self.fields:
                    self.use(field, field['value'], f'field-{field["value"]}', key, 'initialize')
        self.visit(expr, key)

    def visit(self, node, owner):
        kind = node['kind']
        if kind == 'let':
            self.visit_def(node['opdef'], local=True)
            self.visit(node['expr'], owner)
        elif kind == 'lambda':
            for param in node['params']:
                self.symbol(str(param['id']), param['name'], 'parameter', param,
                            param.get('typeAnnotation') or self.inferred(param))
            self.visit(node['expr'], owner)
        elif kind == 'app':
            opcode = node['opcode']
            args = node['args']
            target = self.table.get(str(node['id']))
            if target and target['kind'] in ('def', 'param'):
                self.use(node, opcode, str(target['id']), owner, 'call')
            if opcode in ('field', 'with') and self.is_state(args[0]):
                key = args[1]
                if key.get('value') in self.fields:
                    self.use(key, key['value'], f'field-{key["value"]}', owner,
                             'read' if opcode == 'field' else 'update', tail=opcode == 'field')
                    if opcode == 'field' and args[0]['kind'] == 'name':
                        return  # Treat the field read as one dependency, not two.
            for arg in args:
                self.visit(arg, owner)
        elif kind == 'name':
            target = self.table.get(str(node['id']))
            if target and target['kind'] in ('def', 'param'):
                self.use(node, node['name'], str(target['id']), owner, 'read')

    def fragments(self, start, end):
        cursor = start
        for offset in range(start, end):
            if offset < cursor or offset not in self.tokens:
                continue
            stop, label, target, use = self.tokens[offset]
            if stop > end or target not in self.symbols:
                continue
            yield {'text': self.source[cursor:offset]}
            fragment = {'text': label, 'symbol': target}
            if use is not None:
                fragment['use'] = use
            yield fragment
            cursor = stop
        yield {'text': self.source[cursor:end]}

    def field_fragment(self, node):
        key = str(node['id'])
        target = self.uses.get(key, {}).get('target')
        return {'text': node['value'], 'symbol': target, 'use': key} if target else {'text': node['value']}

    def payload(self, positions=False):
        uses = {key: use for key, use in self.uses.items() if use['target'] in self.symbols}
        if positions:
            line_starts = [0] + [match.end() for match in re.finditer('\n', self.source)]
            for start, (_, _, _, key) in self.tokens.items():
                if key in uses:
                    line = bisect_right(line_starts, start)
                    column = len(self.source[line_starts[line - 1]:start].encode('utf-8'))
                    uses[key] = {**uses[key], 'position': dict(line=line, column=column)}
        return dict(symbols=self.symbols, uses=uses)
