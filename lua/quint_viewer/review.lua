local M = {}
local api = vim.api
local graph_view = require('quint_viewer.graph')
local marks = api.nvim_create_namespace('quint-review-links')
local lsp_util = vim.lsp.util

local function show_definition(result, client)
  if vim.islist(result) then
    if #result > 1 then
      vim.notify('Quint definition lookup returned multiple locations.', vim.log.levels.WARN)
      return
    end
    result = result[1]
  end
  if type(result) ~= 'table' or not lsp_util.show_document(result, client.offset_encoding, {reuse_win = false}) then
    vim.notify('No Quint definition found.', vim.log.levels.INFO)
  end
end

local function show_hover(result)
  local contents = type(result) == 'table' and result.contents
  local format = type(contents) == 'table' and contents.kind == 'plaintext' and 'plaintext' or 'markdown'
  local lines = contents and lsp_util.convert_input_to_markdown_lines(contents) or {}
  if vim.trim(table.concat(lines, '\n')) == '' then
    vim.notify('No Quint hover information found.', vim.log.levels.INFO)
    return
  end
  lsp_util.open_floating_preview(lines, format, {focus = false})
end

local function show_references(result, client)
  if not vim.islist(result) or #result == 0 then
    vim.notify('No Quint references found.', vim.log.levels.INFO)
    return
  end
  local items = lsp_util.locations_to_items(result, client.offset_encoding)
  if vim.fn.setloclist(0, {}, ' ', {title = 'Quint references', items = items}) == 0 then
    vim.cmd.lopen()
  else
    vim.notify('Could not open a location list for Quint references.', vim.log.levels.WARN)
  end
end

local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then return end
  local bytes = file:read('*a')
  file:close()
  return bytes
end

local function matches_buffer(buf, path, bytes)
  if not api.nvim_buf_is_loaded(buf) or api.nvim_buf_get_name(buf) ~= path or vim.bo[buf].modified then
    return false
  end
  -- A loaded buffer can be clean but older than the file on disk. Compare the
  -- document the LSP sees, allowing for Neovim's line ending and BOM handling.
  local options = vim.bo[buf]
  if options.bomb then bytes = bytes:gsub('^\239\187\191', '') end
  if options.fileformat == 'dos' then bytes = bytes:gsub('\r\n', '\n') end
  if options.fileformat == 'mac' then bytes = bytes:gsub('\r', '\n') end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  if options.endofline then text = text .. '\n' end
  return text == bytes
end

local function fresh(buf, path, fingerprint)
  local bytes = read_file(path)
  return bytes and vim.fn.sha256(bytes) == fingerprint and matches_buffer(buf, path, bytes)
end

local function export(path, names)
  local tool = api.nvim_get_runtime_file('tools/export_model.py', false)[1]
  assert(tool, 'could not find the installed model exporter')
  local output = vim.fn.tempname() .. '.qmodel.json'
  local argv = {'python3', '-B', tool, '--source-review', '-o', output, '--', path}
  vim.list_extend(argv, names)
  local result = vim.system(argv, { text = true }):wait()
  local bytes = result.code == 0 and read_file(output)
  vim.fn.delete(output)
  assert(result.code == 0, vim.trim(result.stderr or ''))
  assert(bytes, 'exporter did not produce a model')
  return graph_view.decode(bytes)
end

local function show(source, path, model)
  local lines, targets, folds = graph_view.rows(model,
    'gd definition   K hover   grr references   <C-o> return   za toggle branch')
  local graph = api.nvim_create_buf(false, true)
  vim.bo[graph].bufhidden = 'hide' -- native jump history must be able to return to this buffer
  api.nvim_buf_set_lines(graph, 0, -1, false, lines)
  vim.bo[graph].modifiable = false
  vim.bo[graph].filetype = 'qmodelgraph'
  for row, refs in ipairs(targets) do
    for _, ref in ipairs(refs) do
      local use = ref.use and model.uses[ref.use]
      ref.position = use and use.position
      if ref.position then
        api.nvim_buf_set_extmark(graph, marks, row - 1, ref.col,
          {end_col = ref.end_col, hl_group = 'Underlined'})
      end
    end
  end

  local function check_fresh()
    if fresh(source, path, model.source.sha256) then return true end
    vim.notify('Quint graph is stale; save or reload the source and run :QuintView again.', vim.log.levels.WARN)
    return false
  end

  local request_number = 0
  local function lookup(kind, display)
    local method = 'textDocument/' .. kind
    request_number = request_number + 1
    local request = request_number
    local origin_win = api.nvim_get_current_win()
    local cursor = api.nvim_win_get_cursor(origin_win)
    local position
    for _, ref in ipairs(targets[cursor[1]] or {}) do
      if ref.col <= cursor[2] and cursor[2] < ref.end_col then
        position = ref.position
        break
      end
    end
    if not position or not check_fresh() then return end

    local clients = vim.lsp.get_clients({ bufnr = source, method = method })
    if #clients ~= 1 then
      local why = #clients == 0 and 'No %s-capable LSP client' or 'Multiple %s-capable LSP clients'
      vim.notify(why:format(kind) .. ' attached to the Quint source.', vim.log.levels.WARN)
      return
    end
    local client = clients[1]
    local line = api.nvim_buf_get_lines(source, position.line - 1, position.line, false)[1]
    if not line or position.column < 0 or position.column >= #line then
      vim.notify('Quint graph: invalid source occurrence.', vim.log.levels.WARN)
      return
    end
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(source) },
      position = {
        line = position.line - 1,
        character = vim.str_utfindex(line, client.offset_encoding, position.column),
      },
    }
    if kind == 'references' then params.context = {includeDeclaration = true} end
    local sent = client:request(method, params, function(err, result)
      if request ~= request_number or api.nvim_get_current_win() ~= origin_win
        or api.nvim_get_current_buf() ~= graph or not vim.deep_equal(api.nvim_win_get_cursor(origin_win), cursor) then
        return
      end
      if not check_fresh() then return end
      if err then
        vim.notify(('Quint %s lookup failed: %s'):format(kind, err.message), vim.log.levels.WARN)
        return
      end
      display(result, client)
    end, source)
    if not sent then vim.notify(('Could not send Quint %s lookup.'):format(kind), vim.log.levels.WARN) end
  end

  local function map(key, kind, display, desc)
    vim.keymap.set('n', key, function() lookup(kind, display) end, { buffer = graph, silent = true, desc = desc })
  end
  map('gd', 'definition', show_definition, 'Go to Quint definition')
  map('K', 'hover', show_hover, 'Show Quint hover information')
  map('grr', 'references', show_references, 'Find Quint references')
  -- Keep the saved document (and its LSP attachment) loaded even with 'nohidden'.
  api.nvim_cmd({cmd = 'buffer', args = {tostring(graph)}, mods = {hide = true}}, {})
  vim.b[graph].quint_branch_folds = folds
  local options = vim.wo[0][0]
  options.foldexpr = "get(get(b:, 'quint_branch_folds', []), v:lnum - 1, 0)"
  options.foldtext = "getline(v:foldstart) .. ' …'"
  options.foldmethod = 'expr'
  options.foldminlines = 1
  options.foldenable = true
  options.foldlevel = 99
end

function M.open(names)
  local ok, err = pcall(function()
    local win, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local path = api.nvim_buf_get_name(source)
    assert(vim.bo[source].buftype == '' and vim.endswith(path, '.qnt'), 'open a saved .qnt file first')
    local bytes = read_file(path)
    assert(bytes and matches_buffer(source, path, bytes), 'save or reload the Quint source first')
    local model = export(path, names)
    assert(model.source.sha256 == vim.fn.sha256(bytes) and fresh(source, path, model.source.sha256),
      'the Quint source changed while building the graph; run :QuintView again')
    if api.nvim_get_current_win() == win and api.nvim_get_current_buf() == source then
      show(source, path, model)
    end
  end)
  if not ok then vim.notify('QuintView: ' .. tostring(err), vim.log.levels.ERROR) end
end

return M
