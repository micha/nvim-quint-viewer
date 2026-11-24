-- Drive imported references through the public graph key with the upstream Quint LSP.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local dir = vim.fs.dirname(source)
local policy = vim.fs.joinpath(dir, 'policy.qnt')
local second = vim.fs.joinpath(dir, 'second.qnt')
local source_uri = vim.uri_from_fname(source)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_buf, graph_win, origin
local publications, pending = {}, 0
local notices, lookups = {}, {}

local function printable(value)
  local text = tostring(value)
  if text:find('[^ -~]') or text:find('"', 1, true) or text:find('\\', 1, true) then
    return 'other-' .. (text:gsub('.', function(byte) return ('%02x'):format(byte:byte()) end))
  end
  return text
end

local function fixture_file(path)
  -- Compare exact paths, not basenames that could collide with the fixtures.
  if path == source or path == policy or path == second then return vim.fs.basename(path) end
  return 'other-' .. printable(path)
end

local function integer(value)
  return type(value) == 'number' and value % 1 == 0 and value or -1
end

local function observe_rpc(client)
  -- LspRequest does not expose params. Forward the real request and reply unchanged.
  local send = client.rpc.request
  client.rpc.request = function(method, params, callback, ...)
    -- Restart deliberately shuts down the old client; that is not a lookup.
    if method == 'shutdown' then return send(method, params, callback, ...) end
    local sent, id = send(method, params, function(...)
      callback(...)
      vim.schedule(function() pending = pending - 1 end)
    end, ...)
    if sent then
      local document = type(params) == 'table' and params.textDocument
      local position = type(params) == 'table' and params.position
      local context = type(params) == 'table' and params.context
      local uri = type(document) == 'table' and document.uri
      pending = pending + 1
      lookups[#lookups + 1] = {
        method = printable(method:gsub('^textDocument/', '')),
        position = {
          file = uri == source_uri and 'caller.qnt' or 'other-' .. printable(uri),
          line = integer(type(position) == 'table' and position.line),
          column = integer(type(position) == 'table' and position.character),
        },
        includeDeclaration = type(context) == 'table' and context.includeDeclaration == true,
      }
    end
    return sent, id
  end
end

local function wait_for(buf, uri, previous_id)
  -- The upstream server publishes after parsing and again after analysis.
  local client
  assert(vim.wait(8000, function()
    local clients = vim.lsp.get_clients({bufnr = buf, name = 'quint'})
    client = #clients == 1 and clients[1]
    local counts = client and publications[client.id]
    return counts and client.id ~= previous_id and (counts[uri] or 0) >= 2
  end, 10), 'Quint language server did not finish analyzing ' .. uri)
  return client
end

local function start()
  vim.filetype.add({extension = {qnt = 'quint'}})
  vim.lsp.config('quint', {
    cmd = {'quint-language-server', '--stdio'}, filetypes = {'quint'}, root_dir = dir,
    on_attach = function(client, buf)
      if api.nvim_buf_get_name(buf) == source then observe_rpc(client) end
    end,
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx, config)
        if not err and result then
          local counts = publications[ctx.client_id] or {}
          counts[result.uri] = (counts[result.uri] or 0) + 1
          publications[ctx.client_id] = counts
        end
      end,
    },
  })
  vim.lsp.enable('quint')
  api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  source_buf = api.nvim_get_current_buf()
  wait_for(source_buf, source_uri)
end

local levels = {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local text = tostring(message)
  local reason = printable(message)
  if vim.startswith(text, 'Quint graph is stale') then reason = 'staleGraph'
  elseif vim.startswith(text, 'Quint language server references do not match') then reason = 'staleReferences' end
  notices[#notices + 1] = {level = levels[level] or printable(level), reason = reason}
end

local function edit_buffer(buf)
  api.nvim_buf_set_lines(buf, 0, 0, false, {'// Unsaved edit during replay.'})
end

local actions = {
  init = start,
  openOtherCaller = function()
    local buf = vim.fn.bufadd(second)
    vim.fn.bufload(buf)
    local client = wait_for(buf, vim.uri_from_fname(second))
    assert(client.id == wait_for(source_buf, source_uri).id, 'second caller is not open in the same server')
  end,
  showGraph = function(operator)
    graph_win, origin = api.nvim_get_current_win(), nil
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
  end,
  positionOnCall = function(symbol)
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local first = line:find(symbol .. '(', 1, true)
      -- Do not match bare allowed inside remote::allowed.
      if first and not line:sub(first - 1, first - 1):match('[%w_:]') then
        api.nvim_win_set_cursor(win, {row, first + #symbol - 2})
        origin = {win = win, buf = buf, cursor = api.nvim_win_get_cursor(win)}
        return
      end
    end
    error('cannot find call in rendered graph: ' .. symbol)
  end,
  editCaller = function() edit_buffer(source_buf) end,
  editPolicyBuffer = function()
    local buf = vim.fn.bufadd(policy)
    vim.fn.bufload(buf)
    edit_buffer(buf)
  end,
  editPolicyDisk = function()
    local input = assert(io.open(policy, 'rb'))
    local bytes = assert(input:read('*a'))
    assert(input:close())
    local output = assert(io.open(policy, 'wb'))
    assert(output:write('// Moved the imported declaration.\n', bytes))
    assert(output:close())
  end,
  references = function() api.nvim_feedkeys('grr', 'mx', false) end,
  returnToCaller = function()
    graph_win, origin = nil, nil
    api.nvim_set_current_buf(source_buf)
  end,
  reanalyzeCaller = function()
    local client = wait_for(source_buf, source_uri)
    api.nvim_cmd({cmd = 'lsp', args = {'restart', 'quint'}}, {})
    wait_for(source_buf, source_uri, client.id)
  end,
}

local function observe()
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local focus = buf == source_buf and 'caller.qnt' or vim.bo[buf].filetype == 'qmodelgraph' and 'graph' or 'other'
  local references, loclist_title, graph_read_only = {}, '', false
  if graph_win and api.nvim_win_is_valid(graph_win) then
    local graph = api.nvim_win_get_buf(graph_win)
    graph_read_only = vim.bo[graph].filetype == 'qmodelgraph' and not vim.bo[graph].modifiable
    -- Observe the graph window's native list, not the server's raw locations.
    local list = vim.fn.getloclist(graph_win, {winid = 0, items = 0, title = 0})
    if list.winid == win then focus = 'locationList' end
    loclist_title = printable(list.title)
    for _, item in ipairs(list.items) do
      local name = item.valid == 1 and item.bufnr ~= 0 and api.nvim_buf_is_valid(item.bufnr)
        and api.nvim_buf_get_name(item.bufnr)
      references[#references + 1] = {
        file = fixture_file(name), line = item.lnum, column = item.vcol == 0 and item.col - 1 or -1,
      }
    end
  end
  return {
    windows = #api.nvim_list_wins(), focus = focus, graphReadOnly = graph_read_only,
    graphAtOrigin = origin ~= nil and api.nvim_win_is_valid(origin.win)
      and api.nvim_win_get_buf(origin.win) == origin.buf
      and vim.deep_equal(api.nvim_win_get_cursor(origin.win), origin.cursor),
    loclistTitle = loclist_title, references = references, lookups = lookups, notices = notices,
  }
end

local input = assert(io.open(input_path, 'rb'))
local requests = vim.json.decode(assert(input:read('*a')))
assert(input:close())
local views = {}
for _, request in ipairs(requests) do
  notices, lookups = {}, {}
  assert(actions[request.op], 'unknown replay request: ' .. request.op)(request.arg)
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(8000, function() return drained and pending == 0 end, 10), 'Quint lookup did not complete')
  views[#views + 1] = observe()
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
