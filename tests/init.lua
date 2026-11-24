local root = assert(vim.env.QMODEL_ROOT)
if vim.env.QMODEL_MODE == '--worktree' then
  vim.opt.runtimepath:prepend(root)
else
  vim.pack.add({ vim.uri_from_fname(root) }, { confirm = false })
end

vim.g.qmodel_test_messages = {}
vim.notify = function(message)
  local messages = vim.g.qmodel_test_messages
  messages[#messages + 1] = message
  vim.g.qmodel_test_messages = messages
end
