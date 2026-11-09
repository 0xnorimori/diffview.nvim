local debounce = require("diffview.debounce")
local marks = require("diffview.review.marks")
local utils = require("diffview.utils")

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

local watchers = {}

local function listen(path, recursive, fn)
  local key = path .. (recursive and "\0r" or "")
  local w = watchers[key]
  if not w then
    local handle = vim.uv.new_fs_event()
    if not handle then
      return nil
    end
    w = { handle = handle, subs = {} }
    local ok, res = pcall(handle.start, handle, path, { recursive = recursive }, function(err, name)
      if not err then
        vim.schedule(function()
          for sub in pairs(w.subs) do
            sub(name or "")
          end
        end)
      end
    end)
    if not ok or res ~= 0 then
      handle:close()
      return nil
    end
    watchers[key] = w
  end
  w.subs[fn] = true
  return function()
    w.subs[fn] = nil
    if next(w.subs) == nil and watchers[key] == w then
      watchers[key] = nil
      w.handle:stop()
      w.handle:close()
    end
  end
end

local function comments_changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "NrevCommentsChanged" })
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end
  local nrev = require("nrev")
  local seen = {}
  for _, view in ipairs(lib.views) do
    if view.files and view.adapter and view._nrev_db_watched and view._nrev_listed then
      marks.refresh(view)
    end
    local layout = view.cur_layout
    for _, win in ipairs(layout and layout.windows or {}) do
      local buf = win:is_valid() and vim.api.nvim_win_get_buf(win.id)
      if buf and not seen[buf] then
        seen[buf] = true
        nrev.refresh(buf)
      end
    end
  end
end

local db_changed = debounce.debounce_trailing(150, false, vim.schedule_wrap(comments_changed))

local function rel_path(view, name)
  local top = view.adapter.ctx.toplevel
  if name:sub(1, #top + 1) == top .. "/" then
    return name:sub(#top + 2)
  end
  return name
end

local function worktree_changed(view, name)
  local path = rel_path(view, name)
  if path == ".git" or path:match("^%.git/") then
    return
  end
  for _, file in view.files:iter() do
    if file.path == path then
      local bn = utils.find_file_buffer(file.absolute_path)
      if bn and vim.api.nvim_buf_is_loaded(bn) and not vim.bo[bn].modified then
        pcall(vim.cmd, "checktime " .. bn)
      end
      view:update_files()
      return
    end
  end
end

local function watch(view)
  if view._nrev_watched or not view.emitter then
    return
  end
  view._nrev_watched = true
  view.emitter:on("files_updated", function()
    view._nrev_listed = true
    if view_is_open(view) then
      marks.refresh(view)
    end
  end)
  local stop_db = listen(view.adapter.ctx.dir, false, function(name)
    if vim.startswith(vim.fs.basename(name), "review.db") then
      db_changed()
    end
  end)
  view._nrev_db_watched = stop_db ~= nil
  local stops = { stop_db }
  if view.adapter:has_local(view.left, view.right) then
    table.insert(stops, listen(view.adapter.ctx.toplevel, true, function(name)
      if view_is_open(view) then
        worktree_changed(view, name)
      end
    end))
  end
  view.emitter:on("view_closed", function(_, closed)
    if closed == view then
      for _, stop in pairs(stops) do
        stop()
      end
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
  view._nrev_listed = true
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
        if view.files and view.adapter and not view._nrev_db_watched then
          marks.counts(view)
        end
      end
    end,
  })
end

return M
