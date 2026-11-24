-- Drive the fixture through the public viewer UI and record what Neovim did.
local api = vim.api
local artifact = assert(vim.env.QMODEL_ARTIFACT)
local source = assert(vim.env.QMODEL_SOURCE)
local initial_buf = api.nvim_get_current_buf()
local requests_path = assert(arg[1], 'missing requests path')
local observations_path = assert(arg[2], 'missing observations path')

local anchor = 'allowed = mayApprove('
local symbols = {
  ['approval.review.allowed'] = {heading = 'allowed · local value', offset = 0},
  ['approval.mayApprove'] = {heading = 'mayApprove · function', offset = #'allowed = '},
}
local by_heading = {['Symbol inspector'] = ''}
for id, target in pairs(symbols) do by_heading[target.heading] = id end

-- Keep unrecognized values distinct from every model value without passing
-- arbitrary messages, filenames, or their escaping into Quint string literals.
local function other(value)
  return 'other-' .. (tostring(value):gsub('.', function(byte)
    return ('%02x'):format(byte:byte())
  end))
end

local notices = {}
local levels = {}
for name, level in pairs(vim.log.levels) do levels[level] = name:lower() end
vim.notify = function(message, level)
  local changed = message == 'Source changed after export; regenerate the model to enable source jumps.'
  notices[#notices + 1] = {
    level = levels[level] or other(level),
    reason = changed and 'sourceChanged' or other(message),
  }
end

local function press(keys)
  api.nvim_feedkeys(vim.keycode(keys), 'mx', false)
end

local function current_lines()
  return api.nvim_buf_get_lines(0, 0, -1, false)
end

local actions = {
  init = function() end,
  openArtifact = function()
    api.nvim_cmd({cmd = 'edit', args = {artifact}, magic = {file = false, bar = false}}, {})
  end,
  selectSymbol = function(id)
    local target = assert(symbols[id], 'unknown fixture symbol: ' .. id)
    for row, line in ipairs(current_lines()) do
      local col = line:find(anchor, 1, true)
      if col then
        api.nvim_win_set_cursor(0, {row, col - 1 + target.offset})
        press('<CR>')
        return
      end
    end
    error('cannot find the fixture binding in the graph')
  end,
  focusInspector = function()
    press('<C-w>w')
  end,
  editSource = function()
    local file = assert(io.open(source, 'ab'))
    assert(file:write('\n// Edit after export during replay.\n'))
    assert(file:close())
  end,
  followDefinitionLink = function()
    local in_definition = false
    for row, line in ipairs(current_lines()) do
      if line == 'Definition' then
        in_definition = true
      elseif in_definition then
        if line == 'Selected occurrence' or line:match('^Used by %(') then break end
        if line:match('^↪ Source line %d+$') then
          api.nvim_win_set_cursor(0, {row, 0})
          press('<CR>')
          return
        end
      end
    end
    error('cannot find the inspector Definition link')
  end,
}

local function pane_role(buf)
  local name = api.nvim_buf_get_name(buf)
  if name == source then return 'source' end
  if name == '' and buf == initial_buf then return 'editor' end
  local ft = vim.bo[buf].filetype
  if ft == 'qmodelgraph' then return 'graph' end
  if ft == 'qmodelinspector' then return 'inspector' end
  return 'other'
end

local function observe()
  local panes, selected = {}, nil
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    local role = pane_role(buf)
    panes[#panes + 1] = role
    if role == 'inspector' and not selected then
      local heading = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      selected = by_heading[heading] or other(heading)
    end
  end
  table.sort(panes)

  local focus = pane_role(api.nvim_get_current_buf())
  local destination = {file = '', line = 0, column = 0}
  if focus == 'source' or focus == 'other' then
    local cursor = api.nvim_win_get_cursor(0)
    destination = {file = focus == 'source' and 'approval.qnt' or other(api.nvim_buf_get_name(0)),
      line = cursor[1], column = cursor[2]}
  end
  return {panes = panes, focus = focus, selected = selected or '', destination = destination, notices = notices}
end

local input = assert(io.open(requests_path, 'rb'))
local requests = vim.json.decode(assert(input:read('*a')))
assert(input:close())
local views = {}
for _, request in ipairs(requests) do
  notices = {}
  assert(actions[request.op], 'unknown replay request: ' .. request.op)(request.arg)
  -- The BufReadPost entry point schedules rendering. Drain that callback
  -- without waiting for any particular pane or other expected result.
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(1000, function() return drained end), 'scheduled callback timed out')
  views[#views + 1] = observe()
end
local output = assert(io.open(observations_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
