-- Replay lookups on a re-export through the public graph keys and the real Quint LSP.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local dir = vim.fs.dirname(source)
local wrapper = vim.fs.joinpath(dir, 'wrapper.qnt')
local policy = vim.fs.joinpath(dir, 'policy.qnt')
local source_uri = vim.uri_from_fname(source)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_buf, graph_buf, graph_win, origin
local publications, pending = {}, 0
local hold_method, held_reply
local notices, lookups = {}, {}

local function printable(value)
  local text = tostring(value)
  if text:find('[^ -~]') or text:find('"', 1, true) or text:find('\\', 1, true) then
    return 'other-' .. (text:gsub('.', function(byte) return ('%02x'):format(byte:byte()) end))
  end
  return text
end

local function fixture_file(path)
  -- Compare exact paths; another file with the same basename is not a fixture.
  if path == source or path == policy or path == wrapper then return vim.fs.basename(path) end
  return 'other-' .. printable(path)
end

local function integer(value)
  return type(value) == 'number' and value % 1 == 0 and value or -1
end

local function observe_rpc(client)
  -- Observe real requests and optionally hold the upstream reply before delivery.
  local send = client.rpc.request
  client.rpc.request = function(method, params, callback, ...)
    if method == 'shutdown' then return send(method, params, callback, ...) end
    local hold = method == hold_method
    if hold then hold_method = nil end
    local sent, id = send(method, params, function(err, result, ...)
      if hold then
        local args = {n = select('#', ...), ...}
        held_reply = {
          err = err, result = result,
          deliver = function() callback(err, result, unpack(args, 1, args.n)) end,
        }
      else
        callback(err, result, ...)
      end
      -- This counter tracks replies from the server, not held deliveries.
      vim.schedule(function() pending = pending - 1 end)
    end, ...)
    if sent then
      pending = pending + 1
      local document = type(params) == 'table' and params.textDocument
      local position = type(params) == 'table' and params.position
      local context = type(params) == 'table' and params.context
      local uri = type(document) == 'table' and document.uri
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

local function wait_for_caller(previous_id)
  -- The upstream server publishes after parsing and after analysis.
  local client
  assert(vim.wait(8000, function()
    local clients = vim.lsp.get_clients({bufnr = source_buf, name = 'quint'})
    client = #clients == 1 and clients[1]
    return client and client.id ~= previous_id and (publications[client.id] or 0) >= 2
  end, 10), 'Quint language server did not finish analyzing the caller')
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
        if not err and result and result.uri == source_uri then
          publications[ctx.client_id] = (publications[ctx.client_id] or 0) + 1
        end
      end,
    },
  })
  vim.lsp.enable('quint')
  api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  source_buf = api.nvim_get_current_buf()
  wait_for_caller()
end

local levels = {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local reason = vim.startswith(tostring(message), 'Quint graph is stale') and 'staleGraph' or printable(message)
  notices[#notices + 1] = {level = levels[level] or printable(level), reason = reason}
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'mx', false)
end

local keys = {definition = 'gd', hover = 'K', references = 'grr'}

local function redirect(lines)
  -- Redirect the re-export to the other module without changing either endpoint file.
  local changes = 0
  for i, line in ipairs(lines) do
    local count
    lines[i], count = line:gsub('policy%.%*', 'alternatePolicy.*')
    changes = changes + count
  end
  assert(changes == 2, 'unexpected wrapper fixture')
  return lines
end

local actions = {
  init = start,
  showGraph = function(operator)
    origin = nil
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
    graph_win, graph_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  end,
  positionOnCall = function(symbol)
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local first = line:find(symbol .. '(', 1, true)
      -- Do not match the bare local name inside the qualified call.
      if first and not line:sub(first - 1, first - 1):match('[%w_:]') then
        api.nvim_win_set_cursor(win, {row, first + #symbol - 2})
        origin = api.nvim_win_get_cursor(win)
        return
      end
    end
    error('cannot find call in rendered graph: ' .. symbol)
  end,
  editWrapperDisk = function()
    assert(vim.fn.writefile(redirect(vim.fn.readfile(wrapper)), wrapper) == 0)
  end,
  editWrapperBuffer = function()
    local buf = vim.fn.bufadd(wrapper)
    vim.fn.bufload(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, redirect(api.nvim_buf_get_lines(buf, 0, -1, false)))
  end,
  editCallerBuffer = function()
    api.nvim_buf_set_lines(source_buf, 0, 0, false, {'// Unsaved caller edit.'})
  end,
  definition = function() press(keys.definition) end,
  hover = function() press(keys.hover) end,
  references = function() press(keys.references) end,
  holdLookup = function(method)
    assert(not hold_method and not held_reply, 'already holding a lookup')
    hold_method = 'textDocument/' .. method
    press(assert(keys[method], 'unknown lookup method: ' .. method))
  end,
  deliverReply = function()
    local reply = assert(held_reply, 'no reply held for delivery')
    assert(not reply.err and type(reply.result) == 'table' and next(reply.result),
      'expected a successful, nonempty Quint response')
    held_reply = nil
    reply.deliver()
  end,
  back = function() press('<C-o>') end,
  returnToCaller = function()
    graph_buf, graph_win, origin = nil, nil, nil
    api.nvim_set_current_buf(source_buf)
  end,
  reanalyzeCaller = function()
    local previous_id = wait_for_caller().id
    api.nvim_cmd({cmd = 'lsp', args = {'restart', 'quint'}}, {})
    wait_for_caller(previous_id)
  end,
}

local function observe(op)
  local wins, win, buf = api.nvim_list_wins(), api.nvim_get_current_win(), api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buf)
  local focus = vim.bo[buf].filetype == 'qmodelgraph' and 'graph' or fixture_file(name)
  local position = {file = '', line = 0, column = 0}
  if (op == 'definition' or op == 'deliverReply') and vim.bo[buf].buftype == '' then
    local cursor = api.nvim_win_get_cursor(win)
    position = {file = fixture_file(name), line = cursor[1], column = cursor[2]}
  end

  local hover, references, title = {}, {}, ''
  for _, float in ipairs(wins) do
    if api.nvim_win_get_config(float).relative ~= '' then
      for _, line in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(float), 0, -1, false)) do
        if line ~= '' and line ~= '```quint' and line ~= '```' then hover[#hover + 1] = line end
      end
    end
  end
  if graph_win and api.nvim_win_is_valid(graph_win) then
    -- Observe the graph window's native list, not the server's raw locations.
    local list = vim.fn.getloclist(graph_win, {winid = 0, items = 0, title = 0})
    if list.winid == win then focus = 'locationList' end
    title = printable(list.title)
    for _, item in ipairs(list.items) do
      local path = item.valid == 1 and item.bufnr ~= 0 and api.nvim_buf_is_valid(item.bufnr)
        and api.nvim_buf_get_name(item.bufnr)
      references[#references + 1] = {
        file = fixture_file(path), line = item.lnum, column = item.vcol == 0 and item.col - 1 or -1,
      }
    end
  end
  local graph_in_window = graph_win ~= nil and api.nvim_win_is_valid(graph_win)
    and api.nvim_win_get_buf(graph_win) == graph_buf
  return {
    windows = #wins, focus = focus, position = position, hover = printable(table.concat(hover, ' | ')),
    graphReadOnly = graph_buf ~= nil and api.nvim_buf_is_valid(graph_buf)
      and vim.bo[graph_buf].filetype == 'qmodelgraph' and not vim.bo[graph_buf].modifiable,
    graphAtOrigin = origin ~= nil and graph_in_window and vim.deep_equal(api.nvim_win_get_cursor(graph_win), origin),
    loclistTitle = title, references = references, lookups = lookups, notices = notices,
    heldReply = held_reply ~= nil,
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
  views[#views + 1] = observe(request.op)
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
