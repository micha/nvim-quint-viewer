-- Exercise native folds in the source graph without starting a language server.
local api = vim.api
local source = assert(vim.env.QMODEL_SOURCE)
local input_path, output_path = assert(arg[1]), assert(arg[2])
local ranges, headings, graph_focus = {}, {}, nil

local function index_branches()
  local rows = {}
  for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do rows[line] = row end
  local bounds = {
    outerYes = {'  ├─ Yes', '  │     20'}, outerNo = {'  └─ No', '     30'},
    innerYes = {'  │  ├─ Yes', '  │  │  10'}, innerNo = {'  │  └─ No', '  │     20'},
  }
  graph_focus = 'graph'
  if rows.deep then
    local prefix = '  ' .. ('│  '):rep(19)
    bounds = {depth20Yes = {prefix .. '├─ Yes', prefix .. '│     21'}}
    graph_focus = 'deepGraph'
  end
  for branch, lines in pairs(bounds) do
    local heading, last = unpack(lines)
    local row = assert(rows[heading], 'missing heading: ' .. heading)
    headings[branch] = row
    ranges[row] = {branch = branch, text = heading, last = assert(rows[last], 'missing body: ' .. last)}
  end
end

local actions = {
  init = function()
    api.nvim_cmd({cmd = 'edit', args = {source}, magic = {file = false, bar = false}}, {})
  end,
  showGraph = function(operator)
    api.nvim_cmd({cmd = 'QuintView', args = {operator}}, {})
    index_branches()
  end,
}
for op, keys in pairs({close = 'zc', open = 'zo', toggle = 'za'}) do
  actions[op] = function(branch)
    api.nvim_win_set_cursor(0, {headings[branch], 0})
    api.nvim_feedkeys(keys, 'mx', false)
  end
end

local function observe()
  local focus = 'other'
  if api.nvim_buf_get_name(0) == source then focus = 'source'
  elseif vim.bo.filetype == 'qmodelgraph' then focus = graph_focus end
  local folded, row = {}, 1
  while row <= api.nvim_buf_line_count(0) do
    local first, last = vim.fn.foldclosed(row), vim.fn.foldclosedend(row)
    if first == -1 then
      row = row + 1
    else
      local range, text = ranges[first], vim.fn.foldtextresult(first)
      folded[#folded + 1] = range and range.last == last and vim.startswith(text, range.text)
        and range.branch or 'unexpectedFold'
      row = last + 1
    end
  end
  return {focus = focus, folded = folded}
end

local input = assert(io.open(input_path, 'rb'))
local requests = vim.json.decode(assert(input:read('*a')))
assert(input:close())
local views = {}
for _, request in ipairs(requests) do
  assert(actions[request.op], 'unknown replay request: ' .. request.op)(request.arg)
  views[#views + 1] = observe()
end
local output = assert(io.open(output_path, 'wb'))
assert(output:write(vim.json.encode(views), '\n'))
assert(output:close())
