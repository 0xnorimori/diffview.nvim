local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local oop = require("diffview.oop")

local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local fill = lazy.require("diffview.review.fill") ---@module "diffview.review.fill"
local nrev = lazy.require("nrev") ---@module "nrev"
local nrev_diffview = lazy.require("nrev.diffview") ---@module "nrev.diffview"

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
  self.old_comments = {}
  await(self:render())
  self:load_comments()
end)

function Diff1Inline:load_comments()
  local file = self.a.file
  if not (nrev.enabled and file and file:is_valid()) then
    return
  end
  local info = nrev.buf_info(file.bufnr)
  if not info or info.side ~= "old" then
    return
  end
  nrev.list(info, function(comments)
    if self.rendered_buf and self.a.file == file and (#comments > 0 or #(self.old_comments or {}) > 0) then
      self.old_comments = comments
      self:render()
    end
  end)
end

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

local function removed_lines(old, start, count, gutter, width, notes)
  local out = {}
  for i = start, start + count - 1 do
    local sign = ("−%" .. math.max(gutter - 2, 1) .. "d "):format(i)
    local text = old[i] or ""
    local pad = math.max(width - vim.fn.strdisplaywidth(text), 0)
    table.insert(out, {
      { sign, "DiffviewInlineGutter" },
      { text .. string.rep(" ", pad), "DiffviewInlineDeleted" },
    })
    for _, line in ipairs(notes[i] or {}) do
      table.insert(out, { { string.rep(" ", gutter), "Normal" }, unpack(line) })
    end
    notes[i] = nil
  end
  return out
end

local function comment_notes(comments, old, width)
  local notes = {}
  for _, c in ipairs(comments or {}) do
    local row = math.min(c.line_start, #old)
    if row >= 1 then
      notes[row] = notes[row] or {}
      local drifted = c.status == "open" and old[row] ~= c.line_text
      vim.list_extend(notes[row], nrev.comment_lines(c, drifted, width))
    end
  end
  return notes
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

  local shown = self.rendered_buf == buf and self.topfill
  local cur = api.nvim_win_call(win.id, vim.fn.winsaveview)
  self:clear()
  self.rendered_buf = buf
  local info = vim.fn.getwininfo(win.id)[1]
  local gutter = info and info.textoff or 0
  local width = api.nvim_win_get_width(win.id) - gutter
  local hunks = vim.diff(join(old), join(new), { result_type = "indices" }) or {}
  local notes = comment_notes(self.old_comments, old, width)

  local topfill = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then
      local above = cb > 0 or (sb == 0 and not nulled)
      local row = math.max(sb - 1, 0)
      local virt = removed_lines(old, sa, ca, gutter, width, notes)
      if above and row == 0 then
        topfill = #virt
      end
      api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_lines = virt,
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

  for row, virt in pairs(notes) do
    if #new > 0 then
      local at = math.min(math.max(nrev_diffview.map_line(hunks, row), 1), #new)
      api.nvim_buf_set_extmark(buf, ns, at - 1, 0, { virt_lines = virt })
    end
  end

  self.topfill = topfill
  if topfill > 0 and cur.topline == 1 and (not shown or cur.topfill >= shown) then
    api.nvim_win_call(win.id, function()
      vim.fn.winrestview({ topfill = topfill })
    end)
  end
  self.topline = cur.topline
  self:watch(buf, win.id)
end)

function Diff1Inline:watch(buf, winid)
  local token = {}
  self.listener = token
  self.rerender = debounce.debounce_trailing(150, false, vim.schedule_wrap(function()
    if self.listener == token then
      self:render()
    end
  end))
  api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if self.listener ~= token then
        return true
      end
      self.rerender()
    end,
  })
  self.group = api.nvim_create_augroup("diffview_inline_" .. winid, { clear = true })
  api.nvim_create_autocmd({ "User" }, {
    group = self.group,
    pattern = "NrevCommentsChanged",
    callback = function()
      self:load_comments()
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = self.group,
    callback = function()
      self:load_comments()
    end,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = self.group,
    pattern = tostring(winid),
    callback = function()
      self:restore_topfill(winid)
    end,
  })
end

function Diff1Inline:restore_topfill(winid)
  if not api.nvim_win_is_valid(winid) then
    return
  end
  api.nvim_win_call(winid, function()
    local view = vim.fn.winsaveview()
    local from = self.topline
    self.topline = view.topline
    if from and from > 1 and view.topline == 1 and view.topfill < (self.topfill or 0) then
      vim.fn.winrestview({ topfill = self.topfill })
    end
  end)
end

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
  self.listener = nil
  if self.rerender then
    self.rerender.close()
    self.rerender = nil
  end
  if self.group then
    pcall(api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
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
