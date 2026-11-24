-- Drive imported hover through public keys with the upstream Quint LSP.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local source_uri = vim.uri_from_fname(source)
local policy = vim.fs.joinpath(vim.fs.dirname(source), 'policy.qnt')
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_buf, origin
local lookups, notices = {}, {}
local publications, pending = 0, 0

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
  -- Forward params and replies unchanged; LspRequest does not expose params.
  local send = client.rpc.request
  client.rpc.request = function(method, params, callback, ...)
    local sent, id = send(method, params, function(...)
      callback(...)
      vim.schedule(function() pending = pending - 1 end)
    end, ...)
    if sent then
      pending = pending + 1
      local document = type(params) == 'table' and params.textDocument
      local position = type(params) == 'table' and params.position
      local uri = type(document) == 'table' and document.uri
      lookups[#lookups + 1] = {
        method = printable(method:gsub('^textDocument/', '')),
        position = {
          file = uri == source_uri and 'caller.qnt' or 'other-' .. printable(uri),
          line = integer(type(position) == 'table' and position.line),
          column = integer(type(position) == 'table' and position.character),
        },
      }
    end
    return sent, id
  end
end

local function start()
  vim.filetype.add({extension = {qnt = 'quint'}})
  vim.lsp.config('quint', {
    cmd = {'quint-language-server', '--stdio'}, filetypes = {'quint'}, root_dir = vim.fs.dirname(source),
    on_attach = function(client, buf)
      if api.nvim_buf_get_name(buf) == source then observe_rpc(client) end
    end,
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx, config)
        if not err and result and result.uri == source_uri then publications = publications + 1 end
      end,
    },
  })
  vim.lsp.enable('quint')
  api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  source_buf = api.nvim_get_current_buf()
  assert(vim.wait(8000, function() return publications >= 2 end, 10),
    'Quint language server did not finish analyzing the caller')
end

local levels = {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local stale = vim.startswith(tostring(message), 'Quint graph is stale')
  notices[#notices + 1] = {level = levels[level] or printable(level), reason = stale and 'staleGraph' or printable(message)}
end

local function press(keys)
  api.nvim_feedkeys(keys, 'mx', false)
end

local function edit_buffer(buf)
  api.nvim_buf_set_lines(buf, 0, 0, false, {'// Unsaved edit during replay.'})
end

local actions = {
  init = start,
  showGraph = function(operator)
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
  hover = function() press('K') end,
}

local function observe()
  local wins, win = api.nvim_list_wins(), api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  local focus = buf == source_buf and 'caller.qnt' or vim.bo[buf].filetype == 'qmodelgraph' and 'graph' or 'other'
  local hover = {}
  -- Read the displayed text, not the result handed to the plugin.
  for _, float in ipairs(wins) do
    if api.nvim_win_get_config(float).relative ~= '' then
      for _, line in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(float), 0, -1, false)) do
        line = vim.trim(line)
        if line ~= '' and not line:match('^```[%w_%-]*$') then hover[#hover + 1] = printable(line) end
      end
    end
  end
  return {
    windows = #wins, focus = focus, modifiable = vim.bo[buf].modifiable, hover = hover,
    atOrigin = origin ~= nil and win == origin.win and buf == origin.buf
      and vim.deep_equal(api.nvim_win_get_cursor(win), origin.cursor),
    lookups = lookups, notices = notices,
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
