require("diffview.bootstrap")

local async = require("diffview.async")
local lib = require("diffview.lib")
local utils = require("diffview.utils")

local api = vim.api
local logger = DiffviewGlobal.logger

local M = {}

M.version = 1

local reviews = {}
local subscribers = {}
local last_tab
local toggled_path

local source = debug.getinfo(1, "S").source:sub(2)
local local_nrev = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))) .. "/bin/nrev"

local function notify(kind, path)
  local payload = { event = "review", kind = kind, path = path }
  for chan in pairs(subscribers) do
    if not pcall(vim.rpcnotify, chan, "clubmate", payload) then
      subscribers[chan] = nil
    end
  end
end

local function resolve(tab)
  if not tab then
    local cur = api.nvim_get_current_tabpage()
    tab = reviews[cur] and cur or last_tab
  end
  local view = tab and reviews[tab] and lib.tabpage_to_view(tab)
  if view then
    return view, reviews[tab], tab
  end
end

local function focus(tab)
  if api.nvim_get_current_tabpage() ~= tab then
    api.nvim_set_current_tabpage(tab)
  end
end

local function find(view, path)
  for _, file in view.files:iter() do
    if file.path == path then
      return file
    end
  end
end

local function exclude_specs(globs)
  return vim.tbl_map(function(glob)
    return ":(exclude)" .. glob
  end, globs or {})
end

local function snapshot_reviewed(view, state)
  for _, file in view.files:iter() do
    state.reviewed[file.path] = file.reviewed
  end
end

local function line_count(path)
  local f = io.open(path, "rb")
  if not f then
    return 0
  end
  local n = 0
  for _ in f:lines() do
    n = n + 1
  end
  f:close()
  return n
end

local function count_cmd()
  local bin = vim.fn.executable(local_nrev) == 1 and local_nrev
    or vim.fn.executable("nrev") == 1 and "nrev"
    or nil
  return bin and { bin, "list", "--json", "--status", "open" }
end

local function parse_counts(out)
  local counts = {}
  if out.code ~= 0 or not out.stdout or out.stdout == "" then
    return counts
  end
  local ok, comments = pcall(vim.json.decode, out.stdout)
  if not ok or type(comments) ~= "table" then
    return counts
  end
  for _, c in ipairs(comments) do
    counts[c.file] = (counts[c.file] or 0) + 1
  end
  return counts
end

local function load_counts(view)
  local cmd = count_cmd()
  if not cmd then
    return {}
  end
  local ok, out = pcall(function()
    return vim.system(cmd, { cwd = view.adapter.ctx.toplevel, text = true }):wait(2000)
  end)
  return ok and parse_counts(out) or {}
end

local function refresh_counts(view, state)
  local cmd = count_cmd()
  if not cmd then
    return
  end
  pcall(vim.system, cmd, { cwd = view.adapter.ctx.toplevel, text = true }, function(out)
    vim.schedule(function()
      if reviews[view.tabpage] ~= state then
        return
      end
      local counts = parse_counts(out)
      if not vim.deep_equal(counts, state.counts) then
        state.counts = counts
        notify("comments")
      end
    end)
  end)
end

local open_file

local run_open = async.void(function(view, state, tab, file)
  local ok, err = async.pawait(view.set_file, view, file, true)
  if not ok then
    logger:error("[clubmate] set_file: " .. tostring(err))
  end
  state.opening = false
  local next_file = state.pending_file
  state.pending_file = nil
  if next_file and reviews[tab] == state then
    open_file(view, state, tab, next_file)
  end
end)

function open_file(view, state, tab, file)
  if not state.ready or state.opening then
    state.pending_file = file
    return
  end
  state.opening = true
  focus(tab)
  run_open(view, state, tab, file)
end

local function when_ready(state, fn)
  if state.ready then
    return fn()
  end
  table.insert(state.queue, fn)
end

local function mark_ready(view, state, tab)
  if state.ready then
    return
  end
  state.ready = true
  local queue = state.queue
  state.queue = {}
  vim.schedule(function()
    for _, fn in ipairs(queue) do
      local ok, err = pcall(fn)
      if not ok then
        logger:error("[clubmate] queued call: " .. tostring(err))
      end
    end
    local file = state.pending_file
    state.pending_file = nil
    if file and reviews[tab] == state then
      open_file(view, state, tab, file)
    end
  end)
end

local function watch(view, state)
  view.emitter:on("files_updated", function()
    local changed = false
    for _, file in view.files:iter() do
      if not state.seen[file] then
        state.seen[file] = true
        local mark = state.reviewed[file.path]
        if mark ~= nil and mark ~= file.reviewed then
          file.reviewed = mark
          changed = true
        end
      end
    end
    if changed then
      view.panel:render()
      view.panel:redraw()
    end
    if view.files:len() == 0 then
      mark_ready(view, state, view.tabpage)
    end
    notify("files_updated")
    refresh_counts(view, state)
  end)
  view.emitter:on("file_open_post", function(_, entry)
    mark_ready(view, state, view.tabpage)
    notify("file_open", entry.path)
  end)
  view.emitter:on("view_closed", function()
    reviews[view.tabpage] = nil
    if last_tab == view.tabpage then
      last_tab = nil
    end
  end)
end

local group = api.nvim_create_augroup("diffview_clubmate", { clear = true })

api.nvim_create_autocmd("User", {
  group = group,
  pattern = "DiffviewReviewedToggled",
  callback = function()
    local view, state = resolve(api.nvim_get_current_tabpage())
    if view then
      snapshot_reviewed(view, state)
      notify("reviewed", toggled_path)
    end
  end,
})

api.nvim_create_autocmd("User", {
  group = group,
  pattern = "NrevReviewedRestored",
  callback = function(ev)
    local view, state = resolve(ev.data and ev.data.tabpage)
    if view then
      snapshot_reviewed(view, state)
      notify("reviewed_restored")
    end
  end,
})

api.nvim_create_autocmd("User", {
  group = group,
  pattern = "NrevCommentsChanged",
  callback = function()
    for tab, state in pairs(reviews) do
      local view = lib.tabpage_to_view(tab)
      if view then
        refresh_counts(view, state)
      end
    end
  end,
})

local function open(opts)
  local cwd = opts.cwd and vim.uv.fs_realpath(opts.cwd)
  if not cwd then
    error("cwd does not exist: " .. tostring(opts.cwd), 0)
  end
  local args = { "-C" .. cwd, "--untracked-scoped" }
  if opts.base then
    table.insert(args, opts.base)
  end
  table.insert(args, "--")
  vim.list_extend(args, exclude_specs(opts.excludes))
  local view = lib.diffview_open(args)
  if not view then
    return nil
  end
  view:open()
  view.panel:close()
  local state = {
    reviewed = {},
    seen = setmetatable({}, { __mode = "k" }),
    ready = false,
    queue = {},
  }
  reviews[view.tabpage] = state
  last_tab = view.tabpage
  watch(view, state)
  return view.tabpage
end

local function entries(tab)
  local view, state = resolve(tab)
  if not view then
    return {}
  end
  state.counts = state.counts or load_counts(view)
  return vim.tbl_map(function(file)
    local stats = file.stats or {}
    local additions = stats.additions
    if not additions and file.status == "?" then
      additions = line_count(file.absolute_path)
    end
    return {
      path = file.path,
      status = file.status,
      additions = additions or 0,
      deletions = stats.deletions or 0,
      reviewed = file.reviewed,
      comments = state.counts[file.path] or 0,
    }
  end, view.panel:ordered_file_list())
end

local function select_path(path, tab)
  local view, state, t = resolve(tab)
  if not view then
    return
  end
  local file = find(view, path)
  if file then
    open_file(view, state, t, file)
  elseif not state.ready then
    when_ready(state, function()
      select_path(path, t)
    end)
  end
end

local function toggle_reviewed(path, tab)
  local view, state, t = resolve(tab)
  if not view then
    return nil
  end
  local file = find(view, path)
  if not file then
    if not state.ready then
      when_ready(state, function()
        toggle_reviewed(path, t)
      end)
    end
    return nil
  end
  focus(t)
  file.reviewed = not file.reviewed
  toggled_path = path
  api.nvim_exec_autocmds("User", { pattern = "DiffviewReviewedToggled" })
  toggled_path = nil
  view.panel:render()
  view.panel:redraw()
  return file.reviewed
end

local function next_unreviewed(dir, tab)
  local view, state, t = resolve(tab)
  if not view then
    return nil
  end
  local files = view.panel:ordered_file_list()
  local n = #files
  if n == 0 and not state.ready then
    when_ready(state, function()
      next_unreviewed(dir, t)
    end)
    return nil
  end
  local cur = utils.vec_indexof(files, state.pending_file or view.panel.cur_file)
  local start = cur ~= -1 and cur or (dir > 0 and 0 or n + 1)
  for i = 1, n do
    local file = files[(start - 1 + i * dir) % n + 1]
    if not file.reviewed then
      open_file(view, state, t, file)
      return file.path
    end
  end
  return nil
end

local function set_excludes(globs, tab)
  local view, state, t = resolve(tab)
  if not view then
    return
  end
  snapshot_reviewed(view, state)
  focus(t)
  view:set_path_args(exclude_specs(globs))
end

local function set_panel(visible, tab)
  local view, _, t = resolve(tab)
  if not view then
    return
  end
  if visible then
    focus(t)
    view.panel:open()
  else
    view.panel:close()
  end
end

local function close(tab)
  local view = resolve(tab)
  if view then
    view:close()
    lib.dispose_view(view)
  end
end

local function subscribe(chan)
  subscribers[chan] = true
end

local function guard(name, fn)
  return function(...)
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg, level, opts)
      if level == vim.log.levels.ERROR then
        table.insert(errors, tostring(msg))
        return
      end
      return notify(msg, level, opts)
    end
    local res = vim.F.pack_len(pcall(fn, ...))
    vim.notify = notify
    if not res[1] then
      table.insert(errors, tostring(res[2]))
    end
    if #errors > 0 then
      local msg = table.concat(errors, "\n")
      logger:error("[clubmate] " .. name .. ": " .. msg)
      if not res[1] or res[2] == nil then
        return nil, msg
      end
    end
    return unpack(res, 2, res.n)
  end
end

M.open = guard("open", open)
M.entries = guard("entries", entries)
M.select = guard("select", select_path)
M.toggle_reviewed = guard("toggle_reviewed", toggle_reviewed)
M.next_unreviewed = guard("next_unreviewed", next_unreviewed)
M.set_excludes = guard("set_excludes", set_excludes)
M.set_panel = guard("set_panel", set_panel)
M.close = guard("close", close)
M.subscribe = guard("subscribe", subscribe)

return M
