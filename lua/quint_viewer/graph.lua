local M = {}

function M.decode(text)
  local model = vim.json.decode(text)
  assert(type(model) == 'table' and model.format == 'quint-decision-model' and model.version == 1,
    'expected a quint-decision-model v1 export')
  assert(type(model.source) == 'table' and type(model.source.path) == 'string'
    and type(model.source.sha256) == 'string' and type(model.graphs) == 'table'
    and type(model.symbols) == 'table' and type(model.uses) == 'table' and type(model.module) == 'string',
    'export is missing model data')
  return model
end

function M.rows(model, legend)
  local lines, targets = {}, {}
  local function row(text, ...)
    local refs = {}
    for i = 1, select('#', ...) do
      for _, part in ipairs(select(i, ...)) do
        if part.symbol then
          refs[#refs + 1] = { col = #text, end_col = #text + #part.text, symbol = part.symbol, use = part.use }
        end
        text = text .. part.text
      end
    end
    lines[#lines + 1] = text
    targets[#lines] = refs
  end
  local function literal(text) return {{text = text}} end
  local function walk(node, prefix)
    for _, binding in ipairs(node.bindings) do
      row(prefix, {{text = binding.name, symbol = binding.symbol}}, literal(' = '), binding.expr)
    end
    if node.guard then
      row(prefix .. 'IF ', node.guard)
      row(prefix .. '├─ Yes')
      walk(node.yes, prefix .. '│  ')
      row(prefix .. '└─ No')
      walk(node.no, prefix .. '   ')
    elseif node.outcome then
      local outcome = node.outcome
      row(prefix .. 'Status: ', outcome.status, literal('    Label: '), outcome.label)
      row(prefix .. 'Value:  ', outcome.value, literal('    Count: '), outcome.count)
      if outcome.next_state then
        row(prefix .. 'Next state: ', outcome.next_state)
      elseif #outcome.updates == 0 then
        row(prefix .. 'Next state: unchanged')
      else
        row(prefix .. 'Next state (other fields unchanged):')
        for _, update in ipairs(outcome.updates) do
          row(prefix .. '  ', {update.field}, literal(' ← '), update.value)
        end
      end
    elseif node.unsupported then
      row(prefix .. 'Outside model scope: ', node.unsupported)
    else
      row(prefix, node.expression)
    end
  end
  row('Quint decision model: ' .. model.module)
  row(legend)
  for _, graph in ipairs(model.graphs) do
    row('')
    row(graph.title)
    walk(graph.tree, '  ')
  end
  return lines, targets
end

return M
