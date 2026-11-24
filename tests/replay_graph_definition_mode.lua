-- Replay the public definition keys, retaining real replies until delivery.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local dir = vim.fs.dirname(source)
local policy = vim.fs.joinpath(dir, 'policy.qnt')
local source_uri, policy_uri = vim.uri_from_fname(source), vim.uri_from_fname(policy)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_buf, win, target
local origins, publications, wrapped_clients = {}, {}, {}
local pending = 0
local hold_next, held_reply
local notices, lookups = {}, {}

local function printable(value)
  local text = tostring(value)
  if text:find('[^ -~]') or text:find('"', 1, true) or text:find('\\', 1, true) then
    return 'other-' .. (text:gsub('.', function(byte) return ('%02x'):format(byte:byte()) end))
  end
  return text
end

local function integer(value)
  return type(value) == 'number' and value % 1 == 0 and value or -1
end

local function observe_rpc(client)
  local send = client.rpc.request
  client.rpc.request = function(method, params, callback, ...)
    if method == 'shutdown' then return send(method, params, callback, ...) end
    local hold = method == 'textDocument/definition' and hold_next
    if hold then hold_next = false end
    local sent, id = send(method, params, function(err, result, ...)
      if hold then
        local args = {n = select('#', ...), ...}
        held_reply = {err = err, result = result, deliver = function(delivered)
          callback(err, delivered, unpack(args, 1, args.n))
        end}
      else
        callback(err, result, ...)
      end
      vim.schedule(function() pending = pending - 1 end)
    end, ...)
    if sent then
      pending = pending + 1
      local document = type(params) == 'table' and params.textDocument
      local position = type(params) == 'table' and params.position
      local uri = type(document) == 'table' and document.uri
      lookups[#lookups + 1] = {
        method = printable(method:gsub('^textDocument/', '')),
        file = uri == source_uri and 'caller.qnt' or uri == policy_uri and 'policy.qnt' or 'other-' .. printable(uri),
        position = {
          line = integer(type(position) == 'table' and position.line),
          column = integer(type(position) == 'table' and position.character),
        },
      }
    end
    return sent, id
  end
end

local function wait_for_analysis(buf, uri)
  assert(vim.wait(8000, function()
    local clients = vim.lsp.get_clients({bufnr = buf, name = 'quint'})
    local counts = #clients == 1 and publications[clients[1].id]
    return counts and (counts[uri] or 0) >= 2
  end, 10), 'Quint language server did not finish analyzing ' .. uri)
end

local function start()
  vim.filetype.add({extension = {qnt = 'quint'}})
  vim.lsp.config('quint', {
    cmd = {'quint-language-server', '--stdio'}, filetypes = {'quint'}, root_dir = dir,
    on_attach = function(client, buf)
      if not wrapped_clients[client.id] then
        observe_rpc(client)
        wrapped_clients[client.id] = true
      end
      if api.nvim_buf_get_name(buf) == source then
        -- This is the user's source mapping, not a viewer mapping.
        vim.keymap.set('n', 'gd', vim.lsp.buf.definition, {buffer = buf})
      end
    end,
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx, config)
        if not err and result and result.uri then
          local counts = publications[ctx.client_id] or {}
          counts[result.uri] = (counts[result.uri] or 0) + 1
          publications[ctx.client_id] = counts
        end
      end,
    },
  })
  vim.lsp.enable('quint')
  api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  source_buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  wait_for_analysis(source_buf, source_uri)
end

local reasons = {
  ['Quint graph is stale'] = 'staleGraph',
  ['Quint language server definition is stale'] = 'staleDefinition',
  ['No Quint graph for this definition; use gD to jump to source.'] = 'noGraphUseRaw',
}
local levels = {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local reason = printable(message)
  for prefix, label in pairs(reasons) do
    if vim.startswith(message, prefix) then reason = label; break end
  end
  notices[#notices + 1] = {level = levels[level] or printable(level), reason = reason}
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'mx', false)
end

local function cursor_site()
  return {buf = api.nvim_get_current_buf(), cursor = api.nvim_win_get_cursor(0)}
end

local function select_occurrence(symbol, in_source)
  local pattern = '%f[%w_:]' .. vim.pesc(symbol) .. '%f[^%w_:]'
  -- The binding heading is not an occurrence; select its use in the guard.
  if symbol == 'permitted' then pattern = '%(' .. pattern .. '%)' end
  for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
    if not in_source or line:find('if (', 1, true) then
      local first, last = line:find(pattern)
      if first then
        api.nvim_win_set_cursor(0, {row, in_source and first - 1 or last - (symbol == 'permitted' and 2 or 1)})
        return
      end
    end
  end
  error('cannot find occurrence: ' .. symbol)
end

local actions = {
  init = start,
  showGraph = function(operator)
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
  end,
  selectOccurrence = function(symbol)
    if symbol == 'helper' then
      -- The viewer, not the replay, must open the imported backing buffer.
      local buf = vim.fn.bufnr(policy)
      assert(buf > 0 and api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) == policy,
        'the imported graph has no loaded backing source')
      wait_for_analysis(buf, policy_uri)
    end
    select_occurrence(symbol, false)
    origins[#origins + 1] = cursor_site()
  end,
  editSource = function(which)
    if which == 'callerBuffer' then
      api.nvim_buf_set_lines(source_buf, 0, 0, false, {'// Unsaved caller edit.'})
    elseif which == 'policyDisk' then
      local lines = vim.fn.readfile(policy)
      table.insert(lines, 1, '// Move the declaration by one line.')
      assert(vim.fn.writefile(lines, policy) == 0)
    else
      error('unknown fixture edit: ' .. which)
    end
  end,
  pressDefinition = function(key)
    assert(not held_reply, 'already holding a definition reply')
    hold_next = true
    press(key)
    hold_next = false
  end,
  deliverReply = function(kind)
    local reply = assert(held_reply, 'no definition reply held for delivery')
    assert(not reply.err and type(reply.result) == 'table' and next(reply.result),
      'expected a successful, nonempty Quint definition response')
    held_reply = nil
    local result = reply.result
    if kind == 'wrongScope' then
      local location = assert(result[1], 'expected one LocationLink for the imported call')
      assert(#result == 1 and location.targetUri == policy_uri)
      -- Simulate a stale server pointing at the same name in the caller.
      result = {{uri = source_uri, range = {
        start = {line = 2, character = 11}, ['end'] = {line = 2, character = 18},
      }}}
    else
      assert(kind == 'matching', 'unknown definition reply kind')
    end
    reply.deliver(result)
  end,
  back = function() press('<C-o>') end,
  forward = function() press('<C-i>') end,
  selectSourceCall = function(symbol) select_occurrence(symbol, true) end,
  pressSourceGd = function() press('gd') end,
}

local graph_bodies = {['caller:allowed'] = 'not(ok)', ['policy:allowed'] = 'helper(ok)', ['policy:helper'] = 'ok'}
local function focus(buf)
  if vim.bo[buf].filetype == 'qmodelgraph' then
    local lines = api.nvim_buf_get_lines(buf, 0, 5, false)
    local module = (lines[1] or ''):match('^Quint decision model: (.+)$') or ''
    local name = (lines[4] or '')
    local graph = module .. ':' .. name
    local body = vim.trim(lines[5] or '')
    if graph_bodies[graph] and graph_bodies[graph] ~= body then return 'other-body-' .. printable(body) end
    return printable(graph)
  end
  local name = api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype == '' and (name == source or name == policy) then return vim.fs.basename(name) end
  return 'other-' .. printable(name)
end

local function observe(op, history_before)
  local site = cursor_site()
  if op == 'deliverReply' and site.buf ~= origins[#origins].buf then target = site end
  return {
    windows = #api.nvim_list_wins(), sameWindow = api.nvim_get_current_win() == win,
    focus = focus(site.buf), modifiable = vim.bo[site.buf].modifiable,
    position = {line = site.cursor[1], column = site.cursor[2]},
    atOrigin = vim.iter(origins):any(function(origin) return vim.deep_equal(site, origin) end),
    atTarget = vim.deep_equal(site, target),
    historyChanged = history_before ~= nil and not vim.deep_equal(history_before, vim.fn.getjumplist()),
    heldReply = held_reply ~= nil, lookups = lookups, notices = notices,
  }
end

local input = assert(io.open(input_path, 'rb'))
local requests = vim.json.decode(assert(input:read('*a')))
assert(input:close())
local views = {}
local navigation = {pressDefinition = true, deliverReply = true, back = true, forward = true, pressSourceGd = true}
for _, request in ipairs(requests) do
  notices, lookups = {}, {}
  local history_before = navigation[request.op] and vim.fn.getjumplist() or nil
  assert(actions[request.op], 'unknown replay request: ' .. request.op)(request.arg)
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(8000, function() return drained and pending == 0 end, 10), 'Quint lookup did not complete')
  views[#views + 1] = observe(request.op, history_before)
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
