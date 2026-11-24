local M = {}
local max_fold_depth = 20 -- Neovim's native limit, including expression folds.
local windows = vim.fn.has('win32') == 1

local function relative_path(path)
  return type(path) == 'string' and path ~= '' and not vim.startswith(path, '/')
    and not (windows and (vim.startswith(path, '\\') or path:match('^%a:')))
end

function M.decode(text)
  local model = vim.json.decode(text)
  assert(type(model) == 'table' and model.format == 'quint-decision-model' and model.version == 6,
    'expected a quint-decision-model v6 projection')
  assert(type(model.source) == 'table' and type(model.source.sha256) == 'string'
    and vim.islist(model.modules) and #model.modules > 0
    and type(model.imports) == 'table', 'projection is missing model data')
  for _, module in ipairs(model.modules) do
    assert(type(module) == 'table' and type(module.name) == 'string'
      and vim.islist(module.graphs) and #module.graphs > 0, 'projection is missing module data')
    for _, graph in ipairs(module.graphs) do
      assert(type(graph) == 'table' and type(graph.title) == 'string' and type(graph.tree) == 'table',
        'projection is missing definition data')
    end
  end
  for path, fingerprint in pairs(model.imports) do
    assert(relative_path(path) and type(fingerprint) == 'string' and #fingerprint == 64
      and fingerprint:match('^[0-9a-f]+$'), 'projection has an invalid import fingerprint')
  end
  return model
end

function M.rows(model, legend)
  local lines, targets, folds = {}, {}, {}
  local depth, first_heading = 0, nil
  local function row(text, parts)
    local refs = {}
    for _, part in ipairs(parts or {}) do
      if part.position then
        local target = part.definition_target
        if target then
          assert(type(target) == 'table' and relative_path(target.path)
            and type(target.line) == 'number' and target.line >= 1 and target.line % 1 == 0
            and type(target.column) == 'number' and target.column >= 0 and target.column % 1 == 0
            and type(target.renderable) == 'boolean' and type(target.requires_imports) == 'boolean',
            'projection has an invalid definition position')
        end
        refs[#refs + 1] = {col = #text, end_col = #text + #part.text,
          position = part.position, definition_target = target}
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
  local grouped = #model.modules > 1
  row(grouped and 'Quint decision model' or 'Quint decision model: ' .. model.modules[1].name)
  row(legend)
  for _, module in ipairs(model.modules) do
    if grouped then
      row('')
      row('Module ' .. module.name)
    end
    for _, graph in ipairs(module.graphs) do
      row('')
      row(graph.title)
      first_heading = first_heading or #lines
      walk(graph.tree, '  ')
    end
  end
  return lines, targets, folds, first_heading
end

return M
