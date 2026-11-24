-- Drive :QuintView without a language server; Quint judges the view.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local points = {
  firstName = {3, 'same'}, sameLineBody = {3, '2'}, nestedLocal = {9, 'localValue'},
  outside = {1}, moduleHeader = {2, 'First'}, firstHeader = {2}, secondHeader = {7},
  betweenModules = {6}, wrongModule = {7}, soleModule = {1}, variant = {12, 'Some'},
  filenameFallback = {6}, cursorBeatsFilename = {7}, secondHeaderMac = {7}, emptyFile = {2, 'Some'},
  destructuringFile = {1},
}
local names = {
  firstHeader = {'other', 'same'}, secondHeader = {'same'}, betweenModules = {'same'},
  wrongModule = {'other'}, soleModule = {'decide'}, filenameFallback = {'same'},
  cursorBeatsFilename = {'same'}, secondHeaderMac = {'same'}, [''] = {'same'},
}
local reasons = {
  noDefinitions = 'no top-level operators or values in this file',
  unknownName = 'no operator or value named',
  noModule = 'place the cursor in a Quint module',
  namesNeedSource = 'run :QuintView without names to return to source',
  unsaved = 'save or reload the Quint source first',
}
local source_buf, win, cursor, source_position
local function edit(path)
  api.nvim_cmd({cmd = 'edit', args = {path}, magic = {file = false, bar = false}}, {})
end
local function place(point)
  local row, word = unpack(assert(points[point]))
  local line = api.nvim_buf_get_lines(source_buf, row - 1, row, false)[1]
  api.nvim_win_set_cursor(0, {row, word and assert(line:find(word, 1, true)) - 1 or 0})
  cursor, source_position = api.nvim_win_get_cursor(0), 'entry'
end
local actions = {
  init = function()
    if vim.env.QMODEL_MAC == '1' then vim.opt.fileformats:prepend('mac') end
    edit(source)
    api.nvim_win_set_cursor(0, {1, 0})
    source_buf, win, cursor = api.nvim_get_current_buf(), api.nvim_get_current_win(), api.nvim_win_get_cursor(0)
    source_position = 'start'
  end,
  view = function(point)
    if point ~= '' then place(point) end
    api.nvim_cmd({cmd = 'QuintView'}, {})
  end,
  named = function(point)
    if point ~= '' then place(point) end
    api.nvim_cmd({cmd = 'QuintView', args = names[point]}, {})
  end,
  moveGraph = function() api.nvim_win_set_cursor(0, {2, 5}) end,
  editSource = function()
    api.nvim_buf_set_lines(source_buf, 3, 4, true, {'  pure val after = 4 pure val added = 5'})
  end,
  saveSource = function() api.nvim_cmd({cmd = 'write'}, {}) end,
}

local function observe()
  local focus, position, definitions = 'other', 'other', {}
  local current = api.nvim_win_get_cursor(0)
  if api.nvim_get_current_buf() == source_buf then
    focus = 'source'
    if vim.deep_equal(current, cursor) then position = source_position end
  elseif vim.bo.filetype == 'qmodelgraph' then
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local module_name = (lines[1] or ''):match('^Quint decision model: (.+)$') or ''
    focus = 'graph'
    if vim.deep_equal(current, {1, 0}) then position = 'top' end
    if vim.deep_equal(current, {2, 5}) then position = 'moved' end
    for i = 3, #lines do
      local module_heading = lines[i]:match('^Module (.+)$')
      if module_heading then
        module_name = module_heading
      elseif lines[i]:match('^%S') then
        definitions[#definitions + 1] = module_name .. ':' .. lines[i]
      end
    end
  end
  local notices = {}
  for _, text in ipairs(vim.g.qmodel_test_messages) do
    local name = 'unexpectedNotice'
    for reason, snippet in pairs(reasons) do
      if text:find(snippet, 1, true) then name = reason; break end
    end
    notices[#notices + 1] = name
  end
  return {focus = focus, definitions = definitions, readOnly = not vim.bo.modifiable,
    sameWindow = api.nvim_get_current_win() == win and #api.nvim_tabpage_list_wins(0) == 1,
    position = position, notices = notices}
end

local input = assert(io.open(input_path, 'rb'))
local requests = vim.json.decode(assert(input:read('*a')))
assert(input:close())
local views = {}
for _, request in ipairs(requests) do
  vim.g.qmodel_test_messages = {}
  local ok, err = pcall(assert(actions[request.op], 'unknown request: ' .. request.op), request.arg)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  views[#views + 1] = observe()
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
