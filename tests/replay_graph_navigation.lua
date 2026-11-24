-- Drive the source projection through its public command and keys, with a real Quint LSP.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local source_uri = vim.uri_from_fname(source)
local source_buf, origin
local publications = 0
local requests_sent, pending = 0, {}

-- Observe outbound requests through Neovim's public LSP event, not plugin state.
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

local function parseReady(before)
  -- The pinned upstream server publishes diagnostics after parsing and again
  -- after analysis. This is only a readiness barrier, not a correctness oracle.
  assert(vim.wait(8000, function() return publications >= before + 2 end, 10),
    'Quint language server did not finish analyzing the fixture')
end

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
  api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  source_buf = api.nvim_get_current_buf()
  parseReady(0)
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

local headings = {['  ├─ Yes'] = 'Yes', ['  └─ No'] = 'No'}
local function closed_branches()
  local folded = {}
  for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
    if headings[line] and vim.fn.foldclosed(row) ~= -1 then
      folded[#folded + 1] = headings[line]
    end
  end
  return folded
end

local actions = {
  init = start,
  showGraph = function(operator)
    origin = nil
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
  end,
  closeYesBranch = function()
    for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
      if headings[line] == 'Yes' then
        api.nvim_win_set_cursor(0, {row, 0})
        press('zc')
        return
      end
    end
    error('cannot find outer Yes heading in graph')
  end,
  positionOnCondition = function(symbol)
    for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
      local col = line:find('IF ' .. symbol, 1, true)
      if col then
        -- Put the cursor inside the token, not on its first byte.
        api.nvim_win_set_cursor(0, {row, col + 3})
        origin = {buf = api.nvim_get_current_buf(), cursor = api.nvim_win_get_cursor(0)}
        return
      end
    end
    error('cannot find condition in rendered graph: ' .. symbol)
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
  reloadSource = function()
    local before = publications
    api.nvim_cmd({cmd = 'buffer', args = {tostring(source_buf)}}, {})
    api.nvim_cmd({cmd = 'edit', bang = true}, {})
    api.nvim_win_set_cursor(0, {1, 0})
    parseReady(before)
  end,
  followDefinition = function() press('gD') end,
  back = function() press('<C-o>') end,
}

local function observe()
  local buf, cursor = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)
  local focus = 'other'
  if api.nvim_buf_get_name(buf) == source then focus = 'source'
  elseif vim.bo[buf].filetype == 'qmodelgraph' then focus = 'graph' end
  return {
    windows = #api.nvim_list_wins(), focus = focus, modifiable = vim.bo[buf].modifiable,
    line = focus == 'source' and cursor[1] or 0, column = focus == 'source' and cursor[2] or 0,
    atOrigin = origin ~= nil and buf == origin.buf and vim.deep_equal(cursor, origin.cursor),
    folded = focus == 'graph' and closed_branches() or {},
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
  -- Drain callbacks and wait for any requests actually sent, with no assumption
  -- about whether the key sends a request or where the cursor will end up.
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(8000, function() return drained and next(pending) == nil end, 10),
    'Quint definition request did not complete')
  views[#views + 1] = observe()
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
