local M = {}

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

function M.sync()
  local view = current_view()
  if not view then
    return
  end
  vim.schedule(function()
    local ok, lib = pcall(require, "diffview.lib")
    if not ok or not vim.tbl_contains(lib.views, view) then
      return
    end
    local rev = resolve_rev(view)
    if not rev then
      return
    end
    local cwd = repo_cwd(view)
    local nrev = require("nrev")
    for _, file in view.files:iter() do
      local sub = file.reviewed and "set" or "unset"
      nrev.run({ "reviewed", sub, file.path, "--rev-range", rev }, cwd, nil)
    end
  end)
end

function M.restore(view)
  if view then
    local ok, lib = pcall(require, "diffview.lib")
    if not ok or not vim.tbl_contains(lib.views, view) then
      return
    end
  else
    view = current_view()
    if not view then
      return
    end
  end
  local rev = resolve_rev(view)
  if not rev then
    return
  end
  local cwd = repo_cwd(view)
  require("nrev").run({ "reviewed", "list", "--rev-range", rev }, cwd, function(out)
    if out.code ~= 0 or not out.stdout or out.stdout == "" then
      return
    end
    local set = {}
    for line in out.stdout:gmatch("[^\n]+") do
      set[line] = true
    end
    local changed = false
    for _, file in view.files:iter() do
      if set[file.path] and not file.reviewed then
        file.reviewed = true
        changed = true
      end
    end
    if changed and view.panel then
      view.panel:render()
      view.panel:redraw()
    end
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
      vim.defer_fn(function()
        M.restore(view)
      end, 200)
    end,
  })
end

return M
