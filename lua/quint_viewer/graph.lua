local M = {}
local max_fold_depth = 20 -- Neovim's native limit, including expression folds.

function M.decode(text)
  local model = vim.json.decode(text)
  assert(type(model) == 'table' and model.format == 'quint-decision-model' and model.version == 2,
    'expected a quint-decision-model v2 projection')
  assert(type(model.source) == 'table' and type(model.source.sha256) == 'string'
    and type(model.graphs) == 'table' and type(model.module) == 'string', 'projection is missing model data')
  return model
end

function M.rows(model, legend)
  local lines, targets, folds = {}, {}, {}
  local depth = 0
  local function row(text, parts)
    local refs = {}
    for _, part in ipairs(parts or {}) do
      if part.position then
        refs[#refs + 1] = {col = #text, end_col = #text + #part.text,
          position = part.position, definition_target = part.definition_target}
      end
      text = text .. part.text
    end
    lines[#lines + 1] = text
    targets[#lines] = refs
    folds[#lines] = math.min(depth, max_fold_depth)
  end
  local function walk(node, prefix)
    for _, binding in ipairs(node.bindings) do
      row(prefix .. binding.name .. ' = ', binding.expr)
    end
    if node.guard then
      row(prefix .. 'IF ', node.guard)
      local function branch(heading, indent, child)
        depth = depth + 1
        row(prefix .. heading)
        -- Separate siblings at the same depth. Deeper headings belong to
        -- their ancestor's fold instead of starting a sibling at the limit.
        if depth <= max_fold_depth then folds[#lines] = '>' .. depth end
        walk(child, prefix .. indent)
        depth = depth - 1
      end
      branch('├─ Yes', '│  ', node.yes)
      branch('└─ No', '   ', node.no)
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
  return lines, targets, folds
end

return M
