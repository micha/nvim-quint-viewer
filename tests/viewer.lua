local api = vim.api

local function window(filetype)
  for _, win in ipairs(api.nvim_list_wins()) do
    if vim.bo[api.nvim_win_get_buf(win)].filetype == filetype then return win end
  end
end

local function find(win, text)
  for line, contents in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)) do
    local col = contents:find(text, 1, true)
    if col then return line, col - 1 end
  end
  error('Could not find ' .. text)
end

local function press_enter(win, text, offset)
  local line, col = find(win, text)
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { line, col + (offset or 0) })
  api.nvim_feedkeys('\r', 'mx', false)
end

local function assert_window(filetype)
  assert(vim.wait(1000, function() return window(filetype) ~= nil end), filetype .. ' did not open')
  return window(filetype)
end

local function main()
  local case = vim.env.QMODEL_CASE
  if case == 'ordinary' or case == 'invalid' then
    -- Drain the scheduled BufReadPost callback before inspecting the view.
    local done = false
    vim.schedule(function() done = true end)
    assert(vim.wait(1000, function() return done end))
    assert(#api.nvim_list_wins() == 1 and not window('qmodelgraph'))
    local messages = vim.g.qmodel_test_messages
    if case == 'invalid' then
      assert(#messages == 1 and messages[1]:find('expected a quint-decision-model v1 export', 1, true))
    else
      assert(#messages == 0)
    end
    return
  end

  local graph = assert_window('qmodelgraph')
  local panel = assert_window('qmodelinspector')
  assert(vim.fn.win_screenpos(panel)[2] > vim.fn.win_screenpos(graph)[2])
  assert(not vim.bo[api.nvim_win_get_buf(graph)].modifiable)
  if case == 'stale' then
    find(panel, 'Source changed after export')
    press_enter(graph, 'allowed = mayApprove')
    press_enter(panel, '↪ Source line')
    assert(#api.nvim_list_wins() == 2)
    assert(vim.g.qmodel_test_messages[1]:find('Source changed after export', 1, true))
    return
  end

  press_enter(graph, 'allowed = mayApprove')
  find(panel, 'allowed · local value')
  find(panel, 'Used by (1)')
  find(panel, 'Depends on (3)')
  find(panel, 'mayApprove · call')
  press_enter(panel, 'review · read')
  assert(api.nvim_get_current_win() == graph)
  find(panel, 'Selected occurrence')
  find(panel, 'if (allowed)')
  press_enter(graph, 'label = "approved"')
  find(panel, 'label = "approved"')
  find(panel, 'Used by (1)')
  press_enter(graph, 'label = "denied"')
  find(panel, 'label = "denied"')
  find(panel, 'Used by (1)')
  press_enter(graph, 'pending: false')
  find(panel, 'pending · State field')
  find(panel, 'initial · initialize')
  find(panel, 'review · update')
  press_enter(panel, 'initial · initialize')
  assert(api.nvim_buf_get_name(0):match('/source/approval%.qnt$'))
  assert(#api.nvim_list_wins() == 3)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  api.nvim_err_writeln(err)
  vim.cmd('cquit')
end
vim.cmd('qa!')
