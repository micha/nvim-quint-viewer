local api = vim.api

api.nvim_create_user_command('QuintView', function(command)
  require('quint_viewer.review').open(command.fargs)
end, { nargs = '*', desc = 'View Quint definitions by name or under the cursor' })
