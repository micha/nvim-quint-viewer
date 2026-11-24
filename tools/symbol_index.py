"""Project compiler-resolved references onto decision-graph source fragments."""

from bisect import bisect_right
import re


class Index:
    def __init__(self, definitions, offsets, source, table, definition_targets):
        self.source = source
        self.offsets = offsets
        self.table = table
        self.definition_targets = definition_targets
        self.local_ids = set()
        self.tokens = {}
        self.line_starts = [0] + [match.end() for match in re.finditer('\n', source)]
        for definition in definitions.values():
            if definition['kind'] == 'def':
                self.visit_def(definition)

    def span(self, node):
        _, start, end = self.offsets[str(node['id'])]
        return start['index'], end['index'] + 1

    def visit_def(self, node):
        self.local_ids.add(node['id'])
        self.visit(node['expr'])

    def visit(self, node):
        kind = node['kind']
        if kind == 'let':
            self.visit_def(node['opdef'])
            self.visit(node['expr'])
        elif kind == 'lambda':
            self.local_ids.update(param['id'] for param in node['params'])
            self.visit(node['expr'])
        elif kind == 'app':
            self.use(node, node['opcode'])
            for arg in node['args']:
                self.visit(arg)
        elif kind == 'name':
            self.use(node, node['name'])

    def use(self, node, spelling):
        key = str(node['id'])
        target = self.table.get(key)
        # Lowered destructuring can have compiler-resolved uses with no
        # source span. Index only occurrences actually present in the text.
        if not target or target['kind'] not in ('def', 'param') or key not in self.offsets:
            return
        start, end = self.span(node)
        # Resolve the identity in the compiler table first. The spelling only
        # locates the visible token within the compiler's occurrence span.
        match = re.search(rf'\b{re.escape(spelling)}\b', self.source[start:end])
        if match:
            self.tokens[start + match.start()] = (start + match.end(), spelling, key, target['id'])

    def fragments(self, start, end):
        cursor = start
        for offset in range(start, end):
            if offset < cursor or offset not in self.tokens:
                continue
            stop, label, key, target = self.tokens[offset]
            if stop > end:
                continue
            fragment = {'text': label, 'position': self.position(offset)}
            requires_imports = target not in self.local_ids
            definition_target = self.definition_targets.get(key)
            if requires_imports and not definition_target:
                continue
            if definition_target and (requires_imports or definition_target['renderable']):
                # Graph jumps verify the compiler's destination even for local links.
                fragment['definition_target'] = {**definition_target, 'requires_imports': requires_imports}
            yield {'text': self.source[cursor:offset]}
            yield fragment
            cursor = stop
        yield {'text': self.source[cursor:end]}

    def position(self, start):
        line = bisect_right(self.line_starts, start)
        column = len(self.source[self.line_starts[line - 1]:start].encode('utf-8'))
        return dict(line=line, column=column)
