local M = {}
local api = vim.api
local marks = api.nvim_create_namespace('qmodel-symbols')
local selected_marks = api.nvim_create_namespace('qmodel-selection')

local function scratch(kind)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = kind
  return buf
end

local function write_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function graph_rows(model)
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
  row('<Enter> inspect name   ]s / [s next / previous symbol   q close view')
  for _, graph in ipairs(model.graphs) do
    row('')
    row(graph.title)
    walk(graph.tree, '  ')
  end
  return lines, targets
end

local function check_source(path, fingerprint)
  local file = io.open(path, 'rb')
  if not file then return 'Source is unavailable; source jumps are disabled.' end
  local bytes = file:read('*a')
  file:close()
  if not bytes or vim.fn.sha256(bytes) ~= fingerprint then
    return 'Source changed after export; regenerate the model to enable source jumps.'
  end
  local buffer = vim.fn.bufnr(path)
  if buffer ~= -1 and vim.bo[buffer].modified then
    return 'Source has unsaved edits; source jumps are disabled.'
  end
end

local function show(raw, win, model, graph_lines, targets)
  local source = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(api.nvim_buf_get_name(raw)), model.source.path))
  local graph = scratch('qmodelgraph')
  local inspector, panel_win
  local actions = {}
  local ordered, by_use = {}, {}
  local uses = {}
  for key, use in pairs(model.uses) do uses[#uses + 1] = {key = key, entry = use} end
  table.sort(uses, function(a, b)
    if a.entry.line == b.entry.line then return a.key < b.key end
    return a.entry.line < b.entry.line
  end)

  local warning = check_source(source, model.source.sha256)
  local help = {'Symbol inspector', '', 'Place the cursor on an underlined name and press <Enter>.',
    'Use <C-w>l to enter the inspector on a wide screen.'}
  if warning then vim.list_extend(help, {'', warning}) end
  write_lines(graph, graph_lines)
  for line, refs in ipairs(targets) do
    for _, ref in ipairs(refs) do
      ref.line = line
      ordered[#ordered + 1] = ref
      if ref.use and not by_use[ref.use] then by_use[ref.use] = ref end
      api.nvim_buf_set_extmark(graph, marks, line - 1, ref.col, {end_col = ref.end_col, hl_group = 'Underlined'})
    end
  end

  local function map(buf, key, fn)
    vim.keymap.set('n', key, fn, { buffer = buf, silent = true })
  end

  local function close_panel()
    if panel_win and api.nvim_win_is_valid(panel_win) then api.nvim_win_close(panel_win, false) end
  end

  local function open_panel()
    if panel_win and api.nvim_win_is_valid(panel_win) then return end
    inspector = scratch('qmodelinspector')
    local width = api.nvim_win_get_width(win)
    local split = width >= 80 and 'right' or 'below'
    panel_win = api.nvim_open_win(inspector, false, {split = split, win = win})
    if split == 'right' then api.nvim_win_set_width(panel_win, math.min(48, math.floor(width * 0.38))) end
    vim.wo[panel_win].wrap = true
    map(inspector, 'q', close_panel)
    map(inspector, '<CR>', function()
      local action = actions[api.nvim_win_get_cursor(panel_win)[1]]
      if action then action() end
    end)
  end

  local function jump_source(line)
    local stale = check_source(source, model.source.sha256)
    if stale then
      vim.notify(stale, vim.log.levels.WARN)
      return
    end
    local buf = vim.fn.bufadd(source)
    vim.fn.bufload(buf)
    local source_win = api.nvim_open_win(buf, true, {split = 'above', win = win})
    api.nvim_win_set_cursor(source_win, {math.min(line, api.nvim_buf_line_count(buf)), 0})
  end

  local function go_to(ref)
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, {ref.line, ref.col})
  end

  local function select_symbol(key, occurrence)
    local symbol = model.symbols[key]
    open_panel()
    api.nvim_buf_clear_namespace(graph, selected_marks, 0, -1)
    for _, ref in ipairs(ordered) do
      if ref.symbol == key then
        local hl = occurrence and occurrence == ref.use and 'IncSearch' or 'Search'
        api.nvim_buf_set_extmark(graph, selected_marks, ref.line - 1, ref.col,
          {end_col = ref.end_col, hl_group = hl, priority = 120})
      end
    end
    local lines = {symbol.name .. ' · ' .. symbol.kind, '', symbol.type, '', 'Definition'}
    actions = {}
    vim.list_extend(lines, vim.split(symbol.snippet, '\n', {plain = true}))
    local function link(text, action)
      lines[#lines + 1] = text
      actions[#lines] = action
    end
    link('↪ Source line ' .. symbol.line, function() jump_source(symbol.line) end)
    if occurrence then
      local use = model.uses[occurrence]
      vim.list_extend(lines, {'', 'Selected occurrence', use.snippet})
      link('↪ Source line ' .. use.line, function() jump_source(use.line) end)
    end
    local function section(title, include, incoming)
      local items = vim.tbl_filter(include, uses)
      vim.list_extend(lines, {'', ('%s (%d)'):format(title, #items)})
      for _, item in ipairs(items) do
        local use = item.entry
        local other = model.symbols[incoming and use.owner or use.target]
        local label = other.name .. ' · ' .. use.kind .. ' · line ' .. use.line
        link('↪ ' .. label, function()
          local ref = by_use[item.key]
          if ref then
            go_to(ref)
            select_symbol(ref.symbol, item.key)
          else
            jump_source(use.line)
          end
        end)
      end
    end
    local function writes(use) return use.kind == 'update' or use.kind == 'initialize' end
    section('Used by', function(item) return item.entry.target == key end, true)
    section('Depends on', function(item) return item.entry.owner == key and not writes(item.entry) end, false)
    if vim.iter(uses):any(function(item) return item.entry.owner == key and writes(item.entry) end) then
      section('Writes', function(item) return item.entry.owner == key and writes(item.entry) end, false)
    end
    if warning then vim.list_extend(lines, {'', warning}) end
    write_lines(inspector, lines)
    api.nvim_win_set_cursor(panel_win, {1, 0})
  end

  api.nvim_win_set_buf(win, graph)
  open_panel()
  write_lines(inspector, help)
  api.nvim_create_autocmd('BufWinLeave', {buffer = graph, once = true, callback = function()
    vim.schedule(close_panel)
  end})
  map(graph, 'q', function()
    close_panel()
    if api.nvim_buf_is_valid(raw) then api.nvim_win_set_buf(win, raw) end
  end)
  map(graph, '<CR>', function()
    local pos = api.nvim_win_get_cursor(win)
    for _, ref in ipairs(targets[pos[1]] or {}) do
      if ref.col <= pos[2] and pos[2] < ref.end_col then
        select_symbol(ref.symbol, ref.use)
        return
      end
    end
  end)
  local function step(direction)
    local pos = api.nvim_win_get_cursor(win)
    for i = 1, #ordered do
      local ref = ordered[direction == 1 and i or (#ordered + 1 - i)]
      local order = (ref.line - pos[1])
      if order == 0 then order = ref.col - pos[2] end
      if order * direction > 0 then go_to(ref); return end
    end
  end
  map(graph, ']s', function() step(1) end)
  map(graph, '[s', function() step(-1) end)
end

function M.open(buffer)
  local win = vim.fn.bufwinid(buffer)
  if win == -1 then return end
  local ok, err = pcall(function()
    local model = vim.json.decode(table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), '\n'))
    assert(type(model) == 'table' and model.format == 'quint-decision-model' and model.version == 1,
      'expected a quint-decision-model v1 export')
    assert(type(model.source) == 'table' and type(model.source.path) == 'string'
      and type(model.source.sha256) == 'string' and type(model.graphs) == 'table'
      and type(model.symbols) == 'table' and type(model.uses) == 'table' and type(model.module) == 'string',
      'export is missing model data')
    local lines, targets = graph_rows(model)
    show(buffer, win, model, lines, targets)
  end)
  if not ok then vim.notify('Quint model: ' .. tostring(err), vim.log.levels.ERROR) end
end

return M
