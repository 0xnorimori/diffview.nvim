local api = vim.api

local M = {}

---@param opts? { title?: string }
---@param callback fun(text: string?)
function M.open(opts, callback)
  opts = opts or {}
  local title = opts.title or " Annotation "

  local width = 60
  local height = 3
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("filetype", "diffview_annotation_input", { buf = buf })

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  vim.cmd("startinsert")

  local closed = false
  local function close(text)
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      callback(text)
    end)
  end

  vim.keymap.set("n", "<CR>", function()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      close(nil)
    else
      close(text)
    end
  end, { buffer = buf })

  vim.keymap.set("n", "<Esc>", function()
    close(nil)
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    close(nil)
  end, { buffer = buf })

  api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      close(nil)
    end,
  })
end

return M
