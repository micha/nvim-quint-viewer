-- Replay public source-graph navigation against the real Quint LSP.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local policy = vim.fs.joinpath(vim.fs.dirname(source), 'policy.qnt')
local source_uri = vim.uri_from_fname(source)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_buf, origin
local publications = 0
local requests_sent, pending = 0, {}

api.nvim_create_autocmd('LspRequest', {
  callback = function(ev)
    local data = ev.data
    if data.request.method ~= 'textDocument/definition' then return end
    local id = data.client_id .. ':' .. data.request_id
    if data.request.type == 'pending' then
      requests_sent = requests_sent + 1
      pending[id] = true
    elseif data.request.type == 'complete' then
      pending[id] = nil
    end
  end,
})

local function start()
  vim.filetype.add({extension = {qnt = 'quint'}})
  vim.lsp.config('quint', {
    cmd = {'quint-language-server', '--stdio'}, filetypes = {'quint'}, root_dir = vim.fs.dirname(source),
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx, config)
        if not err and result and result.uri == source_uri then publications = publications + 1 end
      end,
    },
  })
  vim.lsp.enable('quint')
  -- Leave the imported document unopened; the server reads it to resolve the import.
  api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  source_buf = api.nvim_get_current_buf()
  -- The upstream server publishes diagnostics after both parsing and analysis.
  assert(vim.wait(8000, function() return publications >= 2 end, 10),
    'Quint language server did not finish analyzing the caller fixture')
end

local function other(value)
  return 'other-' .. (tostring(value):gsub('.', function(byte)
    return ('%02x'):format(byte:byte())
  end))
end

local notices, levels = {}, {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local stale = tostring(message):find('Quint graph is stale', 1, true) == 1
  notices[#notices + 1] = {level = levels[level] or other(level), reason = stale and 'staleGraph' or other(message)}
end

local function press(keys)
  api.nvim_feedkeys(vim.keycode(keys), 'mx', false)
end

local actions = {
  init = start,
  showGraph = function(operator)
    origin = nil
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
  end,
  positionOnCall = function(symbol)
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local first = line:find(symbol .. '(', 1, true)
      -- The colon makes the imported occurrence distinct from the local call.
      if first and not line:sub(first - 1, first - 1):match('[%w_:]') then
        api.nvim_win_set_cursor(win, {row, first + #symbol - 2})
        origin = {win = win, buf = buf, cursor = api.nvim_win_get_cursor(win)}
        return
      end
    end
    error('cannot find call in rendered graph: ' .. symbol)
  end,
  editCaller = function()
    api.nvim_buf_set_lines(source_buf, 0, 0, false, {'// Unsaved edit during replay.'})
  end,
  followDefinition = function() press('gd') end,
  back = function() press('<C-o>') end,
}

local function observe()
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local cursor, name = api.nvim_win_get_cursor(win), api.nvim_buf_get_name(buf)
  local focus = other(name)
  local is_source = name == source or name == policy
  -- Use fixture IDs only for exact paths; a same-basename file is different.
  if is_source then focus = vim.fs.basename(name)
  elseif vim.bo[buf].filetype == 'qmodelgraph' then focus = 'graph' end
  return {
    windows = #api.nvim_list_wins(), focus = focus, modifiable = vim.bo[buf].modifiable,
    line = is_source and cursor[1] or 0, column = is_source and cursor[2] or 0,
    atOrigin = origin ~= nil and win == origin.win and buf == origin.buf and vim.deep_equal(cursor, origin.cursor),
    definitionRequests = requests_sent, notices = notices,
  }
end

local input = assert(io.open(input_path, 'rb'))
local requests = vim.json.decode(assert(input:read('*a')))
assert(input:close())
local views = {}
for _, request in ipairs(requests) do
  notices, requests_sent = {}, 0
  assert(actions[request.op], 'unknown replay request: ' .. request.op)(request.arg)
  -- Wait for requests actually sent, without assuming that a key sends one.
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(8000, function() return drained and next(pending) == nil end, 10),
    'Quint definition request did not complete')
  views[#views + 1] = observe()
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
