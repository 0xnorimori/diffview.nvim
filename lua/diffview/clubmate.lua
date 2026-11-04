require("diffview.bootstrap")

local async = require("diffview.async")
local lib = require("diffview.lib")
local utils = require("diffview.utils")

local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
local RevType = require("diffview.vcs.rev").RevType
local fill = require("diffview.review.fill")
local review = require("diffview.review.panel")

local api = vim.api
local logger = DiffviewGlobal.logger

local M = {}

M.version = 4

local reviews = {}
local subscribers = {}
local last_tab
local toggled_path
local saved_tabline
local quiet = { depth = 0, sinks = {} }

local QUIET_TIMEOUT = 10000

local source = debug.getinfo(1, "S").source:sub(2)
local local_nrev = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))) .. "/bin/nrev"

local function hush()
  if quiet.depth == 0 then
    quiet.original = vim.notify
    quiet.hook = function(msg, level)
      local text = tostring(msg)
      local sink = quiet.sinks[#quiet.sinks]
      if sink and level == vim.log.levels.ERROR then
        table.insert(sink, text)
      else
        logger:warn("[clubmate] suppressed message: " .. text)
      end
    end
    vim.notify = quiet.hook
  end
  quiet.depth = quiet.depth + 1
end

local function unhush()
  quiet.depth = quiet.depth - 1
  if quiet.depth == 0 then
    if vim.notify == quiet.hook then
      vim.notify = quiet.original
    end
    quiet.original, quiet.hook = nil, nil
  end
end

local function hold()
  hush()
  local released = false
  local function release()
    if not released then
      released = true
      unhush()
    end
  end
  vim.defer_fn(release, QUIET_TIMEOUT)
  return release
end

local function notify(kind, path, tab)
  local payload = { event = "review", kind = kind, path = path, tab = tab }
  for chan in pairs(subscribers) do
    if not pcall(vim.rpcnotify, chan, "clubmate", payload) then
      subscribers[chan] = nil
    end
  end
  local state = reviews[api.nvim_get_current_tabpage()]
  if state and state.layout == "inline" then
    vim.cmd("redrawtabline")
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

local function exclude_specs(globs, escape)
  return vim.tbl_map(function(glob)
    return ":(exclude)" .. (escape and vim.fn.fnameescape(glob) or glob)
  end, globs or {})
end

local function snapshot_reviewed(view, state)
  for _, file in view.files:iter() do
    state.reviewed[file.path] = file.reviewed
  end
end


local function nrev_cmd(status)
  local bin = vim.fn.executable(local_nrev) == 1 and local_nrev
    or vim.fn.executable("nrev") == 1 and "nrev"
    or nil
  return bin and { bin, "list", "--json", "--status", status }
end

local function count_cmd()
  return nrev_cmd("open")
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
        notify("comments", nil, view.tabpage)
      end
    end)
  end)
end

local STRIP = "%!v:lua.require'diffview.clubmate'.strip()"

local function apply_tabline()
  local state = reviews[api.nvim_get_current_tabpage()]
  if state then
    if saved_tabline == nil then
      saved_tabline = { show = vim.o.showtabline, line = vim.o.tabline }
    end
    if state.layout == "inline" then
      vim.o.tabline = STRIP
      vim.o.showtabline = 2
    else
      vim.o.showtabline = 0
      vim.o.tabline = saved_tabline.line
    end
  elseif saved_tabline ~= nil then
    vim.o.showtabline = saved_tabline.show
    vim.o.tabline = saved_tabline.line
    saved_tabline = nil
  end
end

local function esc(text)
  return (text:gsub("%%", "%%%%"))
end

local function short(commit)
  return commit and commit:sub(1, 7) or ""
end

local tag_hls = { added = "DiffviewWinBarTagAdded", deleted = "DiffviewWinBarTagDeleted" }

local function side_tag(view, state, symbol, win)
  local status = view.cur_entry and view.cur_entry.status
  local new, deleted = status == "A" or status == "?", status == "D"
  if symbol == "a" then
    if new then
      return "did not exist"
    end
    if state.turn then
      return "checkpoint " .. short(view.left.commit)
    end
    if state.merge_base == view.left.commit and (state.head or view.left.commit ~= state.tip) then
      return "merge-base " .. short(view.left.commit)
    end
    return nil
  end
  if new then
    return ("new file · %d lines"):format(api.nvim_buf_line_count(api.nvim_win_get_buf(win.id))), "added"
  end
  if deleted then
    return "deleted", "deleted"
  end
  return view.right.type == RevType.LOCAL and "editable" or "read-only"
end

local function winbar(label, path, tag, tone)
  local parts = { "%#DiffviewWinBarLabel# ", esc(label), " " }
  if tag then
    vim.list_extend(parts, { "%#" .. (tag_hls[tone] or "DiffviewWinBarTag") .. "#", esc(tag), " " })
  end
  vim.list_extend(parts, { "%#DiffviewWinBarPath#%<", esc(path) })
  return table.concat(parts)
end

local profile = { number = true, relativenumber = false, cursorline = true, cursorlineopt = "number" }

local function inline_winbar(state, path)
  return table.concat({
    "%#DiffviewWinBarPath# %<", esc(path), " %#DiffviewWinBarTag#inline ",
    "%#DiffviewWinBarLabel#", esc(state.labels.left), " → ", esc(state.labels.right),
  })
end

local function decorate(view, state)
  fill.apply(view)
  local layout = view.cur_layout
  if layout and layout:instanceof(Diff1Inline) then
    local win = layout.b
    if win:is_valid() then
      utils.set_local(win.id, profile)
      vim.wo[win.id].winbar = inline_winbar(state, view.cur_entry and view.cur_entry.path or "")
    end
    return
  end
  for _, win in ipairs(layout and layout.windows or {}) do
    if win:is_valid() and win.file then
      local symbol = win.file.symbol
      local label = symbol == "a" and state.labels.left or state.labels.right
      utils.set_local(win.id, profile)
      local path = win.file.path or (view.cur_entry and view.cur_entry.path) or ""
      vim.wo[win.id].winbar = winbar(label, path, side_tag(view, state, symbol, win))
    end
  end
end

local function layout_class(view, state)
  return state.layout == "inline" and Diff1Inline or view.default_layout
end

local function convert(view, state)
  local cls = layout_class(view, state)
  local cur_changed = false
  for _, entry in view.files:iter() do
    if entry.kind ~= "conflicting" and entry.layout.class ~= cls then
      entry:convert_layout(cls)
      cur_changed = cur_changed or entry == view.cur_entry
    end
  end
  return cur_changed
end

local open_file

local run_open = async.void(function(view, state, tab, file, release)
  local ok, err = async.pawait(view.set_file, view, file, true)
  if not ok then
    logger:error("[clubmate] set_file: " .. tostring(err))
  end
  release()
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
  run_open(view, state, tab, file, hold())
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
    state.release_open()
  end)
end

local function watch(view, state)
  view.emitter:on("files_updated", function()
    if state.layout and convert(view, state) and view.cur_entry then
      open_file(view, state, view.tabpage, view.cur_entry)
    end
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
    notify("files_updated", nil, view.tabpage)
    refresh_counts(view, state)
  end)
  view.emitter:on("file_open_post", function(_, entry)
    mark_ready(view, state, view.tabpage)
    decorate(view, state)
    notify("file_open", entry.path, view.tabpage)
  end)
  view.emitter:on("view_closed", function(_, closed)
    if closed ~= view or reviews[view.tabpage] ~= state then
      return
    end
    state.release_open()
    reviews[view.tabpage] = nil
    vim.schedule(apply_tabline)
    if last_tab == view.tabpage then
      last_tab = nil
    end
    if not state.closing then
      notify("closed", nil, view.tabpage)
    end
  end)
end

local group = api.nvim_create_augroup("diffview_clubmate", { clear = true })

api.nvim_create_autocmd("TabEnter", {
  group = group,
  callback = apply_tabline,
})

api.nvim_create_autocmd("User", {
  group = group,
  pattern = "DiffviewReviewedToggled",
  callback = function()
    local view, state, tab = resolve(api.nvim_get_current_tabpage())
    if view then
      snapshot_reviewed(view, state)
      notify("reviewed", toggled_path, tab)
    end
  end,
})

api.nvim_create_autocmd("User", {
  group = group,
  pattern = "NrevReviewedRestored",
  callback = function(ev)
    local view, state, tab = resolve(ev.data and ev.data.tabpage)
    if view then
      snapshot_reviewed(view, state)
      notify("reviewed_restored", nil, tab)
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

local function git_out(cwd, args)
  local ok, out = pcall(function()
    return vim.system(vim.list_extend({ "git", "-C", cwd }, args), { text = true }):wait(2000)
  end)
  if ok and out.code == 0 then
    return vim.trim(out.stdout)
  end
end

local function is_ref(rev)
  return rev ~= nil and not rev:match("^%x+$")
end

local function checkpoint_turn(cwd, commit)
  local subject = commit and git_out(cwd, { "log", "-1", "--format=%s", commit })
  return subject and (subject:match("^clubmate checkpoint %S+ turn (%d+)$"))
end

local function side_labels(cwd, opts, left)
  local labels = opts.labels or {}
  local turn = checkpoint_turn(cwd, left.commit)
  local function short(rev)
    return git_out(cwd, { "rev-parse", "--short=7", rev }) or rev
  end
  local default_left = turn and ("Before turn " .. turn)
    or (is_ref(opts.base) and opts.base)
    or (left.commit and short(left.commit))
    or "Index"
  local default_right = not opts.head and "Working tree"
    or (is_ref(opts.head) and opts.head)
    or short(opts.head)
  return { left = labels.left or default_left, right = labels.right or default_right }, turn
end

local function open(opts)
  local cwd = opts.cwd and vim.uv.fs_realpath(opts.cwd)
  if not cwd then
    error("cwd does not exist: " .. tostring(opts.cwd), 0)
  end
  local args = { "-C" .. vim.fn.fnameescape(cwd) }
  if opts.head then
    table.insert(args, vim.fn.fnameescape((opts.base or "HEAD") .. "..." .. opts.head))
  else
    table.insert(args, "--untracked-scoped")
    if opts.base then
      table.insert(args, opts.base)
    end
  end
  table.insert(args, "--")
  vim.list_extend(args, exclude_specs(opts.excludes, true))
  local view = lib.diffview_open(args)
  if not view then
    return nil
  end
  local top = view.adapter.ctx.toplevel
  local labels, turn = side_labels(top, opts, view.left)
  local merge_base = opts.head and view.left.commit
    or (view.left.commit and git_out(top, { "merge-base", view.left.commit, "HEAD" }))
  local tip = not opts.head and git_out(top, { "rev-parse", "HEAD" }) or nil
  view.review_labels = labels
  local release = hold()
  local ok, err = pcall(function()
    view:open()
  end)
  if not ok then
    release()
    error(err, 0)
  end
  local state = {
    reviewed = {},
    seen = setmetatable({}, { __mode = "k" }),
    ready = false,
    queue = {},
    release_open = release,
    cwd = cwd,
    host = vim.deepcopy(opts.host),
    excludes = vim.deepcopy(opts.excludes or {}),
    base = opts.base,
    head = opts.head,
    labels = labels,
    turn = turn,
    merge_base = merge_base,
    tip = tip,
    meta = {},
  }
  local tabpage = view.tabpage
  view.panel.host = {
    meta = state.meta,
    send = function()
      notify("send", nil, tabpage)
    end,
  }
  reviews[view.tabpage] = state
  last_tab = view.tabpage
  watch(view, state)
  apply_tabline()
  return view.tabpage
end

local kinds = { A = "new", ["?"] = "new", D = "deleted", R = "renamed" }

local function info(tab)
  local view, state = resolve(tab)
  if not view then
    return nil
  end
  return {
    base = state.base,
    head = state.head,
    merge_base = state.merge_base,
    editable = view.right.type == RevType.LOCAL,
    labels = vim.deepcopy(state.labels),
  }
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
      additions = review.line_count(file.absolute_path)
    end
    local kind = kinds[file.status] or "modified"
    return {
      path = file.path,
      status = file.status,
      additions = additions or 0,
      deletions = stats.deletions or 0,
      reviewed = file.reviewed,
      stale = file.stale or false,
      comments = state.counts[file.path] or 0,
      category = file.review_kind or "code",
      kind = kind,
      old_path = kind == "renamed" and file.oldpath or nil,
    }
  end, view.panel:ordered_file_list())
end

local comment_fields = { "id", "file", "side", "line_start", "line_end", "type", "text", "status", "line_text", "rev" }

local function comments(tab)
  local view = resolve(tab)
  local cmd = view and nrev_cmd("all")
  if not cmd then
    return {}
  end
  local ok, out = pcall(function()
    return vim.system(cmd, { cwd = view.adapter.ctx.toplevel, text = true }):wait(2000)
  end)
  if not ok or out.code ~= 0 or not out.stdout or out.stdout == "" then
    return {}
  end
  local decoded, rows = pcall(vim.json.decode, out.stdout)
  if not decoded or type(rows) ~= "table" then
    return {}
  end
  return vim.tbl_map(function(c)
    local row = {}
    for _, field in ipairs(comment_fields) do
      row[field] = c[field]
    end
    return row
  end, rows)
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

local function set_reviewed(path, want, tab)
  local view, state, t = resolve(tab)
  if not view then
    return nil
  end
  local file = find(view, path)
  if not file then
    if not state.ready then
      when_ready(state, function()
        set_reviewed(path, want, t)
      end)
    end
    return nil
  end
  if want == nil then
    want = not file.reviewed
  end
  if file.reviewed == want then
    return file.reviewed
  end
  focus(t)
  file.reviewed = want
  file.stale = false
  toggled_path = path
  api.nvim_exec_autocmds("User", { pattern = "DiffviewReviewedToggled" })
  toggled_path = nil
  view.panel:refresh_review()
  return file.reviewed
end

local function toggle_reviewed(path, tab)
  return set_reviewed(path, nil, tab)
end

local function next_unreviewed(dir, tab)
  local view, state, t = resolve(tab)
  if not view then
    return nil
  end
  if #view.panel:ordered_file_list() == 0 and not state.ready then
    when_ready(state, function()
      next_unreviewed(dir, t)
    end)
    return nil
  end
  local file = view.panel:next_unreviewed(dir, state.pending_file or view.panel.cur_file)
  if file then
    open_file(view, state, t, file)
    return file.path
  end
  return nil
end

local function redraw_panel(view)
  view.panel:render()
  view.panel:redraw()
end

local function set_meta(tab, meta)
  local view, state = resolve(tab)
  if not view then
    return
  end
  meta = meta or {}
  state.meta.subtitle = meta.subtitle
  state.meta.recipient = meta.recipient
  state.meta.sent = meta.sent
  redraw_panel(view)
end

local function filters(tab)
  local view = resolve(tab)
  return view and view.panel:filters() or nil
end

local function set_filter(name, shown, tab)
  local view = resolve(tab)
  if not view then
    return
  end
  view.panel:set_filter(name, not shown)
  return view.panel:filters()
end

local function set_excludes(globs, tab)
  local view, state, t = resolve(tab)
  if not view then
    return
  end
  snapshot_reviewed(view, state)
  state.excludes = vim.deepcopy(globs or {})
  focus(t)
  local release = hold()
  view.emitter:once("files_updated", function()
    release()
    local nrev = package.loaded["nrev.diffview"]
    if nrev then
      nrev.restore(view)
    end
  end)
  view:set_path_args(exclude_specs(globs))
end

local function set_panel(visible, tab)
  local view, _, t = resolve(tab)
  if not view then
    return
  end
  if visible then
    focus(t)
    if view.panel.drawer then
      view.panel:focus()
    else
      view.panel:open()
    end
  else
    view.panel:close()
  end
end

local function set_layout(layout, tab)
  local view, state, t = resolve(tab)
  if not view then
    return
  end
  if layout ~= "inline" and layout ~= "split" then
    error("unknown layout: " .. tostring(layout), 0)
  end
  local was = state.layout
  state.layout = layout
  if layout == "inline" and was ~= "inline" then
    state.panel_shown = view.panel:is_open()
    view.panel:close()
    view.panel.drawer = true
  elseif layout == "split" and was == "inline" then
    view.panel:close()
    view.panel.drawer = false
    if state.panel_shown ~= false then
      focus(t)
      view.panel:open()
    end
  end
  if api.nvim_get_current_tabpage() == t then
    apply_tabline()
  end
  if convert(view, state) and view.cur_entry then
    open_file(view, state, t, view.cur_entry)
  end
end

local function strip_esc(text)
  return (text:gsub("%%", "%%%%"))
end

function M.strip()
  local tab = api.nvim_get_current_tabpage()
  local view, state = resolve(tab)
  if not view or tab ~= view.tabpage then
    return ""
  end
  local panel = view.panel
  local p = panel:review_progress()
  local open = review.open_comments(panel)
  local cells = 10
  local filled = p.total > 0 and math.floor(cells * p.reviewed / p.total + 0.5) or 0
  local done = review.is_done(p)
  local files = panel:ordered_file_list()
  local cur = state.pending_file or view.cur_entry
  local n = utils.vec_indexof(files, cur)
  local name = cur and vim.fn.fnamemodify(cur.path, ":t") or ""
  return table.concat({
    "%3@v:lua.DiffviewReviewStrip@%#DiffviewReviewMuted# ☰ %#DiffviewReviewTitle#Review%X ",
    done and "%#DiffviewReviewBarDone#" or "%#DiffviewReviewBar#", string.rep("━", filled),
    "%#DiffviewReviewBarTodo#", string.rep("━", cells - filled), " ",
    "%#DiffviewReviewCounter#", ("%d/%d"):format(p.reviewed, p.total),
    "%#DiffviewReviewMuted# · ", open > 0 and "%#DiffviewReviewWarning#" or "%#DiffviewReviewMuted#", open .. " open",
    "%#DiffviewReviewMuted#%=",
    "%1@v:lua.DiffviewReviewStrip@‹%X ",
    "%#DiffviewReviewText#", strip_esc(name), " ",
    "%#DiffviewReviewMuted#", ("%s of %d"):format(n == -1 and "–" or tostring(n), #files),
    " %2@v:lua.DiffviewReviewStrip@›%X ",
  })
end

function _G.DiffviewReviewStrip(minwid)
  local tab = api.nvim_get_current_tabpage()
  local view, state = resolve(tab)
  if not view or tab ~= view.tabpage then
    return
  end
  if minwid == 3 then
    view.panel:toggle(true)
    return
  end
  local files = view.panel:ordered_file_list()
  if #files == 0 then
    return
  end
  local i = utils.vec_indexof(files, state.pending_file or view.cur_entry)
  local target
  if minwid == 2 then
    target = files[i == -1 and 1 or i % #files + 1]
  else
    target = files[i == -1 and #files or (i - 2) % #files + 1]
  end
  open_file(view, state, tab, target)
end

local function close(tab)
  local view, state = resolve(tab)
  if view then
    state.closing = true
    view:close()
    lib.dispose_view(view)
  end
end

local function list_reviews()
  local out = {}
  for tab, state in pairs(reviews) do
    if lib.tabpage_to_view(tab) then
      table.insert(out, {
        tab = tab,
        cwd = state.cwd,
        base = state.base,
        head = state.head,
        labels = vim.deepcopy(state.labels),
        excludes = vim.deepcopy(state.excludes),
        layout = state.layout or "split",
        host = vim.deepcopy(state.host),
      })
    end
  end
  table.sort(out, function(a, b)
    return a.tab < b.tab
  end)
  return out
end

local function subscribe(chan)
  subscribers[chan] = true
end

local function guard(name, fn)
  return function(...)
    local errors = {}
    table.insert(quiet.sinks, errors)
    hush()
    local res = vim.F.pack_len(pcall(fn, ...))
    unhush()
    table.remove(quiet.sinks)
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
M.info = guard("info", info)
M.entries = guard("entries", entries)
M.comments = guard("comments", comments)
M.select = guard("select", select_path)
M.toggle_reviewed = guard("toggle_reviewed", toggle_reviewed)
M.set_reviewed = guard("set_reviewed", set_reviewed)
M.next_unreviewed = guard("next_unreviewed", next_unreviewed)
M.set_excludes = guard("set_excludes", set_excludes)
M.set_meta = guard("set_meta", set_meta)
M.filters = guard("filters", filters)
M.set_filter = guard("set_filter", set_filter)
M.set_panel = guard("set_panel", set_panel)
M.set_layout = guard("set_layout", set_layout)
M.close = guard("close", close)
M.reviews = guard("reviews", list_reviews)
M.subscribe = guard("subscribe", subscribe)

return M
