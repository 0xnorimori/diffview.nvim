local marks = require("diffview.review.marks")

local M = {}

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
