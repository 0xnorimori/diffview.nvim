local RevType = require("diffview.vcs.rev").RevType

local api = vim.api

local M = {}

M.FILLER = "╱"

local ns = api.nvim_create_namespace("diffview_fill")
local buffers = setmetatable({}, { __mode = "k" })
local floats = {}
local columns = {}
local group

local function short(rev)
  if rev.type == RevType.LOCAL then
    return "Working tree"
  end
  if rev.type == RevType.STAGE then
    return "Index"
  end
  return rev.commit and rev.commit:sub(1, 7) or "?"
end

function M.labels(view)
  return view.review_labels or { left = short(view.left), right = short(view.right) }
end

function M.message(view, symbol)
  local labels = M.labels(view)
  if symbol == "a" then
    local left = labels.left == "Index" and "the index" or labels.left:gsub("^Before ", "")
    return "New file — nothing before " .. left
  end
  return "Deleted in " .. (labels.right == "Working tree" and "the working tree" or labels.right)
end

local function filler_buf(win)
  local buf = buffers[win]
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  buffers[win] = buf
  return buf
end

local function close_float(id)
  local f = floats[id]
  floats[id] = nil
  if f and api.nvim_win_is_valid(f.win) then
    pcall(api.nvim_win_close, f.win, true)
  end
end

local function place(id)
  local f = floats[id]
  if not (f and api.nvim_win_is_valid(id) and api.nvim_win_is_valid(f.win)) then
    return close_float(id)
  end
  local info = vim.fn.getwininfo(id)[1]
  local filler = api.nvim_win_call(id, function()
    return vim.fn.diff_filler(1)
  end)
  local rows = math.min(filler, info.height)
  local width = math.min(vim.fn.strdisplaywidth(f.text), info.width - info.textoff)
  if width < 1 then
    return close_float(id)
  end
  api.nvim_win_set_config(f.win, {
    relative = "win",
    win = id,
    row = info.winbar + math.floor(rows / 2),
    col = info.textoff + math.floor((info.width - info.textoff - width) / 2),
    width = width,
    height = 1,
  })
end

local function hatch(id)
  local buf = columns[id] and columns[id].buf
  if not (buf and api.nvim_buf_is_valid(buf) and api.nvim_win_is_valid(id) and api.nvim_win_get_buf(id) == buf) then
    return
  end
  local info = vim.fn.getwininfo(id)[1]
  local line = { { string.rep(M.FILLER, math.max(info.width - info.textoff, 1)), "DiffviewDiffDelete" } }
  local rows = {}
  for _ = 2, info.height do
    rows[#rows + 1] = line
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = line,
    virt_text_pos = "overlay",
    virt_lines = #rows > 0 and rows or nil,
  })
end

local function restore_column(id)
  local saved = columns[id]
  columns[id] = nil
  if saved and api.nvim_win_is_valid(id) then
    vim.wo[id].statuscolumn = saved.statuscolumn
  end
end

local function blank_column(id, buf, width)
  columns[id] = columns[id] or { statuscolumn = vim.wo[id].statuscolumn }
  columns[id].buf = buf
  vim.wo[id].statuscolumn = string.rep(" ", width)
end

local pending = false

local function place_all()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    for id in pairs(floats) do
      place(id)
    end
    for id in pairs(columns) do
      hatch(id)
    end
  end)
end

local function watch()
  if group then
    return
  end
  group = api.nvim_create_augroup("diffview_fill", { clear = true })
  api.nvim_create_autocmd({ "WinResized", "VimResized", "DiffUpdated" }, {
    group = group,
    callback = place_all,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local id = tonumber(ev.match)
      columns[id] = nil
      if floats[id] then
        vim.schedule(function()
          close_float(id)
        end)
      end
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      for id, f in pairs(floats) do
        if not api.nvim_win_is_valid(id) or api.nvim_win_get_buf(id) ~= f.anchor then
          close_float(id)
        end
      end
      for id, c in pairs(columns) do
        if not api.nvim_win_is_valid(id) or api.nvim_win_get_buf(id) ~= c.buf then
          restore_column(id)
        end
      end
    end,
  })
end

local function float(win, buf, text)
  watch()
  local f = floats[win.id]
  text = " " .. text .. " "
  if not (f and api.nvim_win_is_valid(f.win)) then
    local fbuf = api.nvim_create_buf(false, true)
    vim.bo[fbuf].bufhidden = "wipe"
    local fwin = api.nvim_open_win(fbuf, false, {
      relative = "win",
      win = win.id,
      row = 0,
      col = 0,
      width = 1,
      height = 1,
      focusable = false,
      style = "minimal",
      border = "none",
      zindex = 1,
      noautocmd = true,
    })
    vim.wo[fwin].winhighlight = "Normal:DiffviewFillMessage,NormalFloat:DiffviewFillMessage"
    f = { win = fwin, buf = fbuf }
    floats[win.id] = f
  end
  f.anchor, f.text = buf, text
  vim.bo[f.buf].modifiable = true
  api.nvim_buf_set_lines(f.buf, 0, -1, false, { text })
  vim.bo[f.buf].modifiable = false
  place(win.id)
end

function M.float(id)
  local f = floats[id]
  return f and api.nvim_win_is_valid(f.win) and f.win or nil
end

function M.show(win, text, diff)
  local buf = filler_buf(win)
  if api.nvim_win_get_buf(win.id) ~= buf then
    local winbar = vim.wo[win.id].winbar
    api.nvim_win_set_buf(win.id, buf)
    if diff ~= false then
      api.nvim_win_call(win.id, function()
        vim.cmd("diffthis")
      end)
    end
    win:apply_null_winopts()
    vim.wo[win.id].winbar = winbar
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if diff ~= false then
    hatch(win.id)
    return float(win, buf, text)
  end
  close_float(win.id)
  api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { " " .. text .. " ", "DiffviewFillMessage" } },
    virt_text_pos = "overlay",
  })
end

---@param view DiffView
function M.apply(view)
  local layout = view.cur_layout
  local wins = layout and layout.windows or {}
  if #wins < 2 then
    return
  end
  for _, win in ipairs(wins) do
    if win:is_valid() then
      if win.file and win.file.nulled then
        M.show(win, M.message(view, win.file.symbol))
      else
        close_float(win.id)
        restore_column(win.id)
      end
      api.nvim_win_call(win.id, function()
        vim.opt_local.fillchars:append({ diff = M.FILLER })
      end)
    end
  end
end

---@param view DiffView
function M.cover(view)
  local layout = view.cur_layout
  local wins = layout and layout.windows or {}
  if #wins ~= 2 then
    return
  end
  for i, win in ipairs(wins) do
    local partner = wins[3 - i]
    if win:is_valid() and partner:is_valid() and win.file and win.file.nulled then
      watch()
      vim.wo[win.id].number = true
      blank_column(win.id, api.nvim_win_get_buf(win.id), vim.fn.getwininfo(partner.id)[1].textoff)
      hatch(win.id)
    end
  end
end

return M
