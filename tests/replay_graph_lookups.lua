-- Drive source graph lookups through their public keys with the real Quint LSP.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_uri = vim.uri_from_fname(source)
local source_buf, graph_win, origin
local publications, pending = 0, 0
local lookups, notices = {}, {}

local function other(value)
  return 'other-' .. (tostring(value):gsub('.', function(byte)
    return ('%02x'):format(byte:byte())
  end))
end

local function fixture_file(actual, expected)
  -- Identify the exact fixture, not another file with the same basename.
  return actual == expected and vim.fs.basename(source) or other(actual)
end

local function coordinate(value)
  return type(value) == 'number' and value % 1 == 0 and value or -1
end

local methods = {
  ['textDocument/hover'] = 'hover',
  ['textDocument/references'] = 'references',
  ['textDocument/definition'] = 'definition',
}

local function observe_rpc(client)
  -- LspRequest has the method but not the params. Observe at the transport
  -- and forward all requests and responses unchanged to/from the real server.
  local send = client.rpc.request
  client.rpc.request = function(method, params, callback, ...)
    local document = type(params) == 'table' and params.textDocument
    local position = type(params) == 'table' and params.position
    local context = type(params) == 'table' and params.context
    local sent, id = send(method, params, function(...)
      callback(...)
      vim.schedule(function() pending = pending - 1 end)
    end, ...)
    if sent then
      pending = pending + 1
      lookups[#lookups + 1] = {
        method = methods[method] or other(method),
        position = {
          file = fixture_file(type(document) == 'table' and document.uri, source_uri),
          line = coordinate(type(position) == 'table' and position.line),
          column = coordinate(type(position) == 'table' and position.character),
        },
        includeDeclaration = type(context) == 'table' and context.includeDeclaration == true,
      }
    end
    return sent, id
  end
end

local function start()
  vim.filetype.add({extension = {qnt = 'quint'}})
  vim.lsp.config('quint', {
    cmd = {'quint-language-server', '--stdio'}, filetypes = {'quint'}, root_dir = vim.fs.dirname(source),
    on_attach = observe_rpc,
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
  -- The upstream server publishes after parsing and again after analysis.
  assert(vim.wait(8000, function() return publications >= 2 end, 10),
    'Quint language server did not finish analyzing the fixture')
end

local levels = {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local stale = tostring(message):find('Quint graph is stale', 1, true) == 1
  notices[#notices + 1] = {level = levels[level] or other(level), reason = stale and 'staleGraph' or other(message)}
end

local function position_on(find_column, description)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local column = find_column(line)
    if column then
      api.nvim_win_set_cursor(win, {row, column})
      origin = {win = win, buf = buf, cursor = api.nvim_win_get_cursor(win)}
      return
    end
  end
  error('cannot find ' .. description .. ' in rendered graph')
end

local keys = {hover = 'K', references = 'grr'}
local actions = {
  init = start,
  showGraph = function(operator)
    graph_win = api.nvim_get_current_win()
    origin = nil
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
  end,
  positionOnCondition = function(symbol)
    position_on(function(line)
      local col = line:find('IF ' .. symbol, 1, true)
      -- Put the cursor inside the occurrence, not at its first byte.
      return col and col + 3
    end, 'condition ' .. symbol)
  end,
  positionOnHeading = function()
    position_on(function(line)
      return line == '  ├─ Yes' and #'  ├─ Y' or nil
    end, 'outer Yes heading')
  end,
  editSource = function(kind)
    if kind == 'buffer' then
      api.nvim_buf_set_lines(source_buf, 0, 0, false, {'// Unsaved edit during replay.'})
    else
      assert(kind == 'disk', 'unexpected edit kind: ' .. kind)
      local read = assert(io.open(source, 'rb'))
      local text = assert(read:read('*a'))
      assert(read:close())
      local write = assert(io.open(source, 'wb'))
      assert(write:write('// Disk edit during replay.\n', text))
      assert(write:close())
    end
  end,
  lookup = function(method)
    api.nvim_feedkeys(assert(keys[method], 'unknown lookup: ' .. method), 'mx', false)
  end,
}

local function hover_declaration(wins)
  local first_lines = {}
  for _, win in ipairs(wins) do
    if api.nvim_win_get_config(win).relative ~= '' then
      -- Inspect the actual float, not the server result or the plugin's state.
      -- Skip leading whitespace and the opening Markdown fence, if present.
      local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
      local first = ''
      for _, line in ipairs(lines) do
        line = vim.trim(line)
        if line ~= '' and not line:match('^```[%w_%-]*$') then
          first = line
          break
        end
      end
      first_lines[#first_lines + 1] = first
    end
  end
  local text = table.concat(first_lines, ' | ')
  -- Preserve printable text literally when it can be quoted in Quint.
  if text:find('[^ -~]') or text:find('"', 1, true) or text:find('\\', 1, true) then return other(text) end
  return text
end

local function observe()
  local wins, win = api.nvim_list_wins(), api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local focus, references = 'other', {}
  if buf == source_buf then focus = 'source'
  elseif vim.bo[buf].filetype == 'qmodelgraph' then focus = 'graph' end

  if graph_win and api.nvim_win_is_valid(graph_win) then
    -- A quickfix list or another window's location list cannot satisfy this.
    local loclist = vim.fn.getloclist(graph_win, {winid = 0, items = 0})
    if loclist.winid == win then focus = 'locationList' end
    for _, item in ipairs(loclist.items) do
      local name = item.valid == 1 and item.bufnr ~= 0 and api.nvim_buf_is_valid(item.bufnr)
        and api.nvim_buf_get_name(item.bufnr)
      references[#references + 1] = {
        file = fixture_file(name, source), line = item.lnum, column = item.vcol == 0 and item.col - 1 or -1,
      }
    end
  end

  return {
    windows = #wins, focus = focus, hover = hover_declaration(wins), references = references,
    graphAtOrigin = origin ~= nil and api.nvim_win_is_valid(origin.win)
      and api.nvim_win_get_buf(origin.win) == origin.buf
      and vim.deep_equal(api.nvim_win_get_cursor(origin.win), origin.cursor),
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
  -- Wait based on work observed at the transport, not on whether the key is
  -- expected to send a request or what it is supposed to display.
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(8000, function() return drained and pending == 0 end, 10),
    'Quint lookup did not complete')
  views[#views + 1] = observe()
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
