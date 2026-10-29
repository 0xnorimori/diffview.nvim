require("diffview.bootstrap")

local lib = require("diffview.lib")
local utils = require("diffview.utils")

local api = vim.api

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

local function snapshot_reviewed(view, state)
  for _, file in view.files:iter() do
    state.reviewed[file.path] = file.reviewed
  end
end

local function set_path_args(view, globs)
  local specs = vim.tbl_map(function(glob)
    return ":(exclude)" .. glob
  end, globs or {})
  view.path_args = specs
  view.panel.path_args = specs
  view.adapter.ctx.path_args = specs
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

local function nrev_bin()
  if vim.fn.executable(local_nrev) == 1 then
    return local_nrev
  end
  if vim.fn.executable("nrev") == 1 then
    return "nrev"
  end
end

local function comment_counts(cwd)
  local counts = {}
  local bin = nrev_bin()
  if not bin then
    return counts
  end
  local ok, out = pcall(function()
    local cmd = { bin, "list", "--json", "--status", "open" }
    return vim.system(cmd, { cwd = cwd, text = true }):wait(2000)
  end)
  if not ok or out.code ~= 0 or not out.stdout or out.stdout == "" then
    return counts
  end
  local decoded, comments = pcall(vim.json.decode, out.stdout)
  if not decoded or type(comments) ~= "table" then
    return counts
  end
  for _, c in ipairs(comments) do
    counts[c.file] = (counts[c.file] or 0) + 1
  end
  return counts
end

local function open_file(view, tab, file)
  focus(tab)
  view:set_file(file, true)
end

local function watch(view)
  view.emitter:on("files_updated", function()
    local state = reviews[view.tabpage]
    local changed = false
    for _, file in view.files:iter() do
      local mark = state and state.reviewed[file.path]
      if mark ~= nil and mark ~= file.reviewed then
        file.reviewed = mark
        changed = true
      end
    end
    if changed then
      view.panel:render()
      view.panel:redraw()
    end
    notify("files_updated")
  end)
  view.emitter:on("file_open_post", function(_, entry)
    notify("file_open", entry.path)
  end)
end

api.nvim_create_autocmd("User", {
  group = api.nvim_create_augroup("diffview_clubmate", { clear = true }),
  pattern = "DiffviewReviewedToggled",
  callback = function()
    local view, state = resolve(api.nvim_get_current_tabpage())
    if view then
      snapshot_reviewed(view, state)
      notify("reviewed", toggled_path)
    end
  end,
})

function M.open(opts)
  local args = { "-C" .. opts.cwd }
  if opts.base then
    table.insert(args, opts.base)
  end
  local view = lib.diffview_open(args)
  if not view then
    return nil
  end
  set_path_args(view, opts.excludes)
  view:open()
  view.panel:close()
  reviews[view.tabpage] = { reviewed = {} }
  last_tab = view.tabpage
  watch(view)
  return view.tabpage
end

function M.entries(tab)
  local view = resolve(tab)
  if not view then
    return {}
  end
  local counts = comment_counts(view.adapter.ctx.toplevel)
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
      comments = counts[file.path] or 0,
    }
  end, view.panel:ordered_file_list())
end

function M.select(path, tab)
  local view, _, t = resolve(tab)
  local file = view and find(view, path)
  if file then
    open_file(view, t, file)
  end
end

function M.toggle_reviewed(path, tab)
  local view, _, t = resolve(tab)
  local file = view and find(view, path)
  if not file then
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

function M.next_unreviewed(dir, tab)
  local view, _, t = resolve(tab)
  if not view then
    return nil
  end
  local files = view.panel:ordered_file_list()
  local n = #files
  local cur = utils.vec_indexof(files, view.panel.cur_file)
  local start = cur ~= -1 and cur or (dir > 0 and 0 or n + 1)
  for i = 1, n do
    local file = files[(start - 1 + i * dir) % n + 1]
    if not file.reviewed then
      open_file(view, t, file)
      return file.path
    end
  end
  return nil
end

function M.set_excludes(globs, tab)
  local view, state, t = resolve(tab)
  if not view then
    return
  end
  snapshot_reviewed(view, state)
  set_path_args(view, globs)
  focus(t)
  view:update_files()
end

function M.set_panel(visible, tab)
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

function M.close(tab)
  local view, _, t = resolve(tab)
  if view then
    view:close()
    lib.dispose_view(view)
  end
  t = t or tab
  if t then
    reviews[t] = nil
    if last_tab == t then
      last_tab = nil
    end
  end
end

function M.subscribe(chan)
  subscribers[chan] = true
end

return M
