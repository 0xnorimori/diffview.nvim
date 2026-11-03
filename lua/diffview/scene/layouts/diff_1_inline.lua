local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local oop = require("diffview.oop")

local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local fill = lazy.require("diffview.review.fill") ---@module "diffview.review.fill"

local api = vim.api
local await = async.await

local M = {}

local ns = api.nvim_create_namespace("diffview_inline")

---@class Diff1Inline : Diff1
---@field a { file: vcs.File }
local Diff1Inline = oop.create_class("Diff1Inline", Diff1)

Diff1Inline.name = "diff1_inline"

---@class Diff1Inline.init.Opt
---@field a vcs.File
---@field b vcs.File
---@field winid_b integer

---@param opt Diff1Inline.init.Opt
function Diff1Inline:init(opt)
  self:super(opt)
  self.a = { file = opt.a }
end

function Diff1Inline:files()
  local files = Diff1.files(self)
  if self.a.file then
    table.insert(files, 1, self.a.file)
  end
  return files
end

function Diff1Inline:is_files_loaded()
  return self.b.file == nil or self.b.file:is_valid()
end

---@param self Diff1Inline
---@param entry FileEntry
Diff1Inline.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as Diff1Inline ]]
  assert(layout:instanceof(Diff1Inline))

  self:set_file_b(layout.b.file)
  self.a = { file = layout.a.file }

  if self:is_valid() then
    await(self:open_files())
  end
end)

---@param self Diff1Inline
Diff1Inline.open_files = async.void(function(self)
  await(Diff1.open_files(self))
  await(self:render())
end)

local function lines_of(file)
  if not file or file.nulled then
    return {}
  end
  if not file:is_valid() then
    local ok = async.pawait(file.create_buffer, file)
    if not ok or not file:is_valid() then
      return {}
    end
  end
  return api.nvim_buf_get_lines(file.bufnr, 0, -1, false)
end

local function join(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

local function removed_lines(old, start, count, gutter, width)
  local out = {}
  for i = start, start + count - 1 do
    local sign = ("−%" .. math.max(gutter - 2, 1) .. "d "):format(i)
    local text = old[i] or ""
    local pad = math.max(width - vim.fn.strdisplaywidth(text), 0)
    table.insert(out, {
      { sign, "DiffviewInlineGutter" },
      { text .. string.rep(" ", pad), "DiffDelete" },
    })
  end
  return out
end

---@param self Diff1Inline
Diff1Inline.render = async.void(function(self)
  local win = self.b
  local old = lines_of(self.a.file)
  await(async.scheduler())
  if not win:is_valid() then return end

  local nulled = win.file and win.file.nulled
  if nulled then
    fill.show(win, fill.message(self:view() or {}, "b"), false)
  end

  local buf = api.nvim_win_get_buf(win.id)
  local new = nulled and {} or api.nvim_buf_get_lines(buf, 0, -1, false)

  vim.wo[win.id].diff = false
  vim.wo[win.id].scrollbind = false
  vim.wo[win.id].cursorbind = false
  vim.wo[win.id].foldenable = false

  self:clear()
  self.rendered_buf = buf
  local info = vim.fn.getwininfo(win.id)[1]
  local gutter = info and info.textoff or 0
  local width = api.nvim_win_get_width(win.id) - gutter
  local hunks = vim.diff(join(old), join(new), { result_type = "indices" }) or {}

  local topfill = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then
      local above = cb > 0 or (sb == 0 and not nulled)
      local row = math.max(sb - 1, 0)
      if above and row == 0 then
        topfill = ca
      end
      api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_lines = removed_lines(old, sa, ca, gutter, width),
        virt_lines_above = above,
        virt_lines_leftcol = true,
      })
    end
    for i = sb, sb + cb - 1 do
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        line_hl_group = "DiffAdd",
        sign_text = "+",
        sign_hl_group = "DiffviewInlineAdded",
      })
    end
  end

  if topfill > 0 then
    api.nvim_win_call(win.id, function()
      if vim.fn.line("w0") == 1 then
        vim.fn.winrestview({ topfill = topfill })
      end
    end)
  end
end)

function Diff1Inline:view()
  for _, view in ipairs(require("diffview.lib").views) do
    if view.cur_layout == self then
      return view
    end
  end
end

function Diff1Inline:clear()
  local buf = self.rendered_buf
  self.rendered_buf = nil
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

function Diff1Inline:detach_files()
  self:clear()
  Diff1.detach_files(self)
end

function Diff1Inline:destroy()
  self:clear()
  Diff1.destroy(self)
end

function Diff1Inline.should_null(rev, status, sym)
  return Diff2.__get().should_null(rev, status, sym)
end

M.Diff1Inline = Diff1Inline
M.ns = ns
return M
