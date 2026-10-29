local M = {}

local RETRY_INTERVAL = 300
local RETRY_TIMEOUT = 5000

local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  if not view or not view.files or not view.left or not view.adapter then
    return nil
  end
  return view
end

local function view_is_open(view)
  local ok, lib = pcall(require, "diffview.lib")
  return ok and vim.tbl_contains(lib.views, view)
end

local function repo_cwd(view)
  local ctx = view.adapter and view.adapter.ctx
  return ctx and ctx.toplevel or vim.uv.cwd()
end

local function resolve_rev(view)
  local rev = view.left.commit
  if not rev then
    local ok, head = pcall(view.adapter.head_rev, view.adapter)
    rev = ok and head and head.commit or nil
  end
  return rev
end

local function working_entries(view)
  local entries = {}
  for _, file in view.files:iter() do
    if file.kind == "working" then
      table.insert(entries, file)
    end
  end
  return entries
end

function M.sync()
  local view = current_view()
  if not view then
    return
  end
  vim.schedule(function()
    if not view_is_open(view) then
      return
    end
    local rev = resolve_rev(view)
    if not rev then
      return
    end
    local cwd = repo_cwd(view)
    local nrev = require("nrev")
    local snapshot = view._nrev_synced
    if snapshot and snapshot.rev ~= rev then
      snapshot = nil
    end
    local next_flags = {}
    for _, file in ipairs(working_entries(view)) do
      local flag = file.reviewed and true or false
      if snapshot == nil then
        if flag then
          nrev.run({ "reviewed", "set", file.path, "--rev-range", rev }, cwd, nil)
        end
      else
        local prev = snapshot.flags[file.path]
        if prev == nil then
          if flag then
            nrev.run({ "reviewed", "set", file.path, "--rev-range", rev }, cwd, nil)
          end
        elseif prev ~= flag then
          local sub = flag and "set" or "unset"
          nrev.run({ "reviewed", sub, file.path, "--rev-range", rev }, cwd, nil)
        end
      end
      next_flags[file.path] = flag
    end
    view._nrev_synced = { rev = rev, flags = next_flags }
  end)
end

local function has_files(view)
  for _ in view.files:iter() do
    return true
  end
  return false
end

local function poll_until_populated(view, elapsed, cb)
  if not view_is_open(view) then
    return
  end
  if has_files(view) then
    cb()
    return
  end
  if elapsed >= RETRY_TIMEOUT then
    return
  end
  vim.defer_fn(function()
    poll_until_populated(view, elapsed + RETRY_INTERVAL, cb)
  end, RETRY_INTERVAL)
end

local function do_restore(view)
  local rev = resolve_rev(view)
  if not rev then
    return
  end
  local cwd = repo_cwd(view)
  require("nrev").run({ "reviewed", "list", "--rev-range", rev }, cwd, function(out)
    if not view_is_open(view) then
      return
    end
    if out.code ~= 0 then
      return
    end
    local reviewed_paths = {}
    if out.stdout and out.stdout ~= "" then
      for line in out.stdout:gmatch("[^\n]+") do
        reviewed_paths[line] = true
      end
    end
    local changed = false
    local flags = {}
    for _, file in ipairs(working_entries(view)) do
      if reviewed_paths[file.path] and not file.reviewed then
        file.reviewed = true
        changed = true
      end
      flags[file.path] = file.reviewed and true or false
    end
    view._nrev_synced = { rev = rev, flags = flags }
    if changed and view.panel then
      view.panel:render()
      view.panel:redraw()
    end
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NrevReviewedRestored",
      data = { tabpage = view.tabpage },
    })
  end)
end

function M.restore(view)
  if view then
    if not view_is_open(view) then
      return
    end
  else
    view = current_view()
    if not view then
      return
    end
  end
  poll_until_populated(view, 0, function()
    do_restore(view)
  end)
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
      if not view then
        return
      end
      M.restore(view)
    end,
  })
end

return M
