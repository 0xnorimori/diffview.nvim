local marks = require("diffview.review.marks")

local M = {}

local filler_ns = vim.api.nvim_create_namespace("nrev_filler")
local FILLER = "╱"
local fillers = {}

local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  if not view or not view.files or not view.adapter then
    return nil
  end
  return view
end

local function view_is_open(view)
  local ok, lib = pcall(require, "diffview.lib")
  return ok and vim.tbl_contains(lib.views, view)
end

local function watch(view)
  if view._nrev_watched or not view.emitter then
    return
  end
  view._nrev_watched = true
  view.emitter:on("files_updated", function()
    if view_is_open(view) then
      marks.refresh(view)
    end
  end)
end

function M.sync()
  local view = current_view()
  if not view then
    return
  end
  vim.schedule(function()
    if view_is_open(view) then
      marks.sync(view)
    end
  end)
end

function M.restore(view)
  view = view or current_view()
  if not view or not view_is_open(view) then
    return
  end
  watch(view)
  marks.refresh(view)
end

local function partner_wins(bufnr)
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return {}
  end
  for _, view in ipairs(lib.views) do
    local layout = view.cur_layout
    local wins = layout and layout.windows or {}
    for _, win in ipairs(wins) do
      if win:is_valid() and vim.api.nvim_win_get_buf(win.id) == bufnr then
        return vim.tbl_filter(function(other)
          return other ~= win and other:is_valid() and vim.wo[other.id].diff
            and vim.api.nvim_win_get_buf(other.id) ~= bufnr
        end, wins)
      end
    end
  end
  return {}
end

local function text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
end

local function hunk_end(start, count)
  return count > 0 and start + count or start + 1
end

function M.map_line(hunks, row)
  local offset = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local before = ca == 0 and row <= sa or row < sa
    if before then
      return row + offset
    end
    if ca > 0 and row < sa + ca then
      local k = row - sa
      if cb == 0 then
        return sb
      end
      return k < cb and sb + k or sb + cb - 1
    end
    offset = hunk_end(sb, cb) - hunk_end(sa, ca)
  end
  return row + offset
end

local function clear(bufnr)
  local placed = fillers[bufnr]
  fillers[bufnr] = nil
  for _, p in ipairs(placed or {}) do
    if vim.api.nvim_buf_is_valid(p.buf) then
      pcall(vim.api.nvim_buf_del_extmark, p.buf, filler_ns, p.id)
    end
  end
end

function M.fill(bufnr, placed)
  clear(bufnr)
  if #placed == 0 then
    return
  end
  local own = {}
  fillers[bufnr] = own
  for _, other in ipairs(partner_wins(bufnr)) do
    local obuf = vim.api.nvim_win_get_buf(other.id)
    local count = vim.api.nvim_buf_line_count(obuf)
    local hunks = vim.diff(text(bufnr), text(obuf), { result_type = "indices" }) or {}
    local info = vim.fn.getwininfo(other.id)[1]
    local width = math.max(vim.api.nvim_win_get_width(other.id) - (info and info.textoff or 0), 1)
    local line = { { string.rep(FILLER, width), "DiffviewDiffDelete" } }
    for _, p in ipairs(placed) do
      local row = math.min(math.max(M.map_line(hunks, p.row), 1), count)
      local virt = {}
      for _ = 1, p.lines do
        table.insert(virt, line)
      end
      local id = vim.api.nvim_buf_set_extmark(obuf, filler_ns, row - 1, 0, { virt_lines = virt })
      table.insert(own, { buf = obuf, id = id })
    end
  end
end

local function rerender_tab()
  local nrev = require("nrev")
  local seen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not seen[buf] then
      seen[buf] = true
      nrev.rerender(buf)
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("nrev-diffview", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewReviewedToggled",
    callback = function()
      M.sync()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewOpened",
    callback = function()
      local view = current_view()
      if view then
        watch(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function()
      vim.schedule(rerender_tab)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NrevCommentsChanged",
    callback = function()
      local ok, lib = pcall(require, "diffview.lib")
      if not ok then
        return
      end
      for _, view in ipairs(lib.views) do
        if view.files and view.adapter then
          marks.counts(view)
        end
      end
    end,
  })
end

return M
