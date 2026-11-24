local api = vim.api

api.nvim_create_autocmd('BufReadPost', {
  group = api.nvim_create_augroup('QuintModelViewer', { clear = true }),
  pattern = '*.qmodel.json',
  desc = 'Open a generated Quint model in the decision viewer',
  callback = function(event)
    vim.schedule(function()
      if api.nvim_buf_is_valid(event.buf) then
        require('quint_viewer').open(event.buf)
      end
    end)
  end,
})
