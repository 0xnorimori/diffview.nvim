local api = vim.api

local M = {}

local state = {
  win = nil,
  buf = nil,
  entries = {},
}

local type_label = {
  add = "(+)",
  remove = "(-)",
  context = "(ctx)",
  file = "(file)",
}

local function format_entry(e)
  local loc
  if e.type == "file" then
    loc = string.format("%s %s", e.file, type_label[e.type])
  else
    loc = string.format("%s:%d %s", e.file, e.lnum, type_label[e.type] or "(ctx)")
  end

  local short_text = #e.text > 50 and e.text:sub(1, 47) .. "..." or e.text
  short_text = short_text:gsub("\n", " ")
  return string.format("  %-40s  %s", loc, short_text)
end

local function close()
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
  state.entries = {}
end

local function position_cursor(view, entry)
  local layout = view.cur_layout
  if not layout then return end
  local win = (entry.side == "a" and layout.a or layout.b)
  if win and api.nvim_win_is_valid(win.id) then
    api.nvim_set_current_win(win.id)
    pcall(api.nvim_win_set_cursor, win.id, { entry.lnum, 0 })
    vim.cmd("normal! zz")
  end
end

local function jump_to_entry(view, entry)
  close()

  if entry.type == "file" then
    view.panel:focus()
    return
  end

  local cur_file = view.panel.cur_file
  if not cur_file or cur_file.path ~= entry.file then
    for _, f in view.panel.files:iter() do
      if f.path == entry.file then
        view.pending_annot_jump = entry
        view.emitter:once("file_open_post", function()
          if view.pending_annot_jump == entry then
            view.pending_annot_jump = nil
            position_cursor(view, entry)
          end
        end)
        view:set_file(f, true)
        return
      end
    end
  else
    position_cursor(view, entry)
  end
end

---@param view DiffView
function M.open(view)
  if not view.annot_store:has_any() then
    vim.notify("No annotations", vim.log.levels.INFO)
    return
  end

  state.entries = view.annot_store:get_all()
  local lines = {}
  for _, e in ipairs(state.entries) do
    table.insert(lines, format_entry(e))
  end

  local max_line = 0
  for _, l in ipairs(lines) do
    max_line = math.max(max_line, #l)
  end

  local width = math.min(math.max(max_line + 4, 40), math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  state.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = state.buf })
  api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })

  state.win = api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format(" Annotations (%d) ", #state.entries),
    title_pos = "center",
  })

  api.nvim_set_option_value("cursorline", true, { win = state.win })
  api.nvim_set_option_value("winhighlight", "CursorLine:Visual", { win = state.win })

  vim.keymap.set("n", "<CR>", function()
    local idx = api.nvim_win_get_cursor(state.win)[1]
    local entry = state.entries[idx]
    if entry then
      jump_to_entry(view, entry)
    end
  end, { buffer = state.buf })

  vim.keymap.set("n", "<Esc>", close, { buffer = state.buf })
  vim.keymap.set("n", "q", close, { buffer = state.buf })
  vim.keymap.set("n", "@", close, { buffer = state.buf })

  api.nvim_create_autocmd("BufLeave", {
    buffer = state.buf,
    once = true,
    callback = close,
  })
end

function M.is_open()
  return state.win ~= nil and api.nvim_win_is_valid(state.win)
end

---@param view DiffView
function M.toggle(view)
  if M.is_open() then
    close()
  else
    M.open(view)
  end
end

return M
