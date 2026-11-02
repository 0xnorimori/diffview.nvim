local config = require("diffview.config")
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")
local Panel = require("diffview.ui.panel").Panel
local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree
local api = vim.api
local M = {}

---@class TreeOptions
---@field flatten_dirs boolean
---@field folder_statuses "never"|"only_folded"|"always"

---@class FilePanel : Panel
---@field adapter VCSAdapter
---@field files FileDict
---@field path_args string[]
---@field rev_pretty_name string|nil
---@field cur_file FileEntry
---@field listing_style "list"|"tree"
---@field tree_options TreeOptions
---@field render_data RenderData
---@field components CompStruct
---@field constrain_cursor function
---@field help_mapping string
---@field hidden { tests: boolean, generated: boolean, reviewed: boolean }
---@field visible { conflicting: FileEntry[], working: FileEntry[], staged: FileEntry[] }
---@field visible_trees { conflicting: FileTree, working: FileTree, staged: FileTree }
local FilePanel = oop.create_class("FilePanel", Panel)

FilePanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
    opt = { method = "prepend" },
  },
})

FilePanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFiles",
})

---FilePanel constructor.
---@param adapter VCSAdapter
---@param files FileEntry[]
---@param path_args string[]
function FilePanel:init(adapter, files, path_args, rev_pretty_name)
  local conf = config.get_config()
  self:super({
    config = conf.file_panel.win_config,
    bufname = "DiffviewFilePanel",
  })
  self.adapter = adapter
  self.files = files
  self.path_args = path_args
  self.rev_pretty_name = rev_pretty_name
  self.listing_style = conf.file_panel.listing_style
  self.tree_options = conf.file_panel.tree_options
  local filters = conf.file_panel.filters
  self.hidden = {
    tests = filters.tests.hidden,
    generated = filters.generated.hidden,
    reviewed = filters.reviewed.hidden,
  }

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@override
function FilePanel:open()
  FilePanel.super_class.open(self)
  vim.cmd("wincmd =")
end

function FilePanel:setup_buffer()
  local conf = config.get_config()

  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for _, mapping in ipairs(conf.keymaps.file_panel) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end

  local help_keymap = config.find_help_keymap(conf.keymaps.file_panel)
  if help_keymap then self.help_mapping = help_keymap[2] end
end

---@param file FileEntry
---@return boolean
function FilePanel:counted(file)
  if file.review_kind == "test" then
    return not self.hidden.tests
  elseif file.review_kind == "generated" then
    return not self.hidden.generated
  end
  return true
end

---@param file FileEntry
---@return boolean
function FilePanel:visible_file(file)
  return self:counted(file) and not (self.hidden.reviewed and file.reviewed)
end

function FilePanel:update_components()
  local fold_state = self:save_fold_state()
  local conflicting_files
  local working_files
  local staged_files

  self.visible = {}
  self.visible_trees = {}
  for _, kind in ipairs({ "conflicting", "working", "staged" }) do
    self.visible[kind] = vim.tbl_filter(function(file)
      return self:visible_file(file)
    end, self.files[kind])
  end

  if self.listing_style == "list" then
    conflicting_files = { name = "files" }
    working_files = { name = "files" }
    staged_files = { name = "files" }

    for _, file in ipairs(self.visible.conflicting) do
      table.insert(conflicting_files, {
        name = "file",
        context = file,
      })
    end

    for _, file in ipairs(self.visible.working) do
      table.insert(working_files, {
        name = "file",
        context = file,
      })
    end

    for _, file in ipairs(self.visible.staged) do
      table.insert(staged_files, {
        name = "file",
        context = file,
      })
    end

  elseif self.listing_style == "tree" then
    for _, kind in ipairs({ "conflicting", "working", "staged" }) do
      self.visible_trees[kind] = FileTree(self.visible[kind])
      self.visible_trees[kind]:update_statuses()
    end

    conflicting_files = utils.tbl_merge(
      { name = "files" },
      self.visible_trees.conflicting:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs,
      })
    )

    working_files = utils.tbl_merge(
      { name = "files" },
      self.visible_trees.working:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs,
      })
    )

    staged_files = utils.tbl_merge(
      { name = "files" },
      self.visible_trees.staged:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs,
      })
    )
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    { name = "path" },
    {
      name = "conflicting",
      { name = "title" },
      conflicting_files,
      { name = "margin" },
    },
    {
      name = "working",
      { name = "title" },
      working_files,
      { name = "margin" },
    },
    {
      name = "staged",
      { name = "title" },
      staged_files,
      { name = "margin" },
    },
    {
      name = "info",
      { name = "title" },
      { name = "entries" },
    },
    { name = "hints" },
  })
  self:restore_fold_state(fold_state)

  self.constrain_cursor = renderer.create_cursor_constraint({
    self.components.conflicting.files.comp,
    self.components.working.files.comp,
    self.components.staged.files.comp,
  })
end

---@return FileEntry[]
function FilePanel:ordered_file_list()
  if not self.visible then
    return {}
  end

  if self.listing_style == "list" then
    return utils.vec_join(self.visible.conflicting, self.visible.working, self.visible.staged)
  else
    local nodes = utils.vec_join(
      self.visible_trees.conflicting.root:leaves(),
      self.visible_trees.working.root:leaves(),
      self.visible_trees.staged.root:leaves()
    )

    return vim.tbl_map(function(node)
      return node.data
    end, nodes) --[[@as vector ]]
  end
end

function FilePanel:set_cur_file(file)
  if self.cur_file then
    self.cur_file:set_active(false)
  end

  self.cur_file = file
  if self.cur_file then
    self.cur_file:set_active(true)
  end
end

function FilePanel:prev_file()
  local files = self:ordered_file_list()
  if not self.cur_file and self.files:len() > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    self:set_cur_file(files[(i - vim.v.count1 - 1) % #files + 1])
    return self.cur_file
  elseif #files > 0 then
    self:set_cur_file(files[#files])
    return self.cur_file
  end
end

function FilePanel:next_file()
  local files = self:ordered_file_list()
  if not self.cur_file and self.files:len() > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    self:set_cur_file(files[(i + vim.v.count1 - 1) % #files + 1])
    return self.cur_file
  elseif #files > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end
end

---Get the file entry under the cursor.
---@return (FileEntry|DirData)?
function FilePanel:get_item_at_cursor()
  if not self:is_open() and self:buf_loaded() then return end

  local line = api.nvim_win_get_cursor(self.winid)[1]
  local comp = self.components.comp:get_comp_on_line(line)
  if comp and comp.name == "file" then
    return comp.context
  elseif comp and comp.name == "dir_name" then
    return comp.parent.context
  end
end

---Get the parent directory data of the item under the cursor.
---@return DirData?
---@return RenderComponent?
function FilePanel:get_dir_at_cursor()
  if self.listing_style ~= "tree" then return end
  if not self:is_open() and self:buf_loaded() then return end

  local line = api.nvim_win_get_cursor(self.winid)[1]
  local comp = self.components.comp:get_comp_on_line(line)

  if not comp then return end

  if comp.name == "dir_name" then
    local dir_comp = comp.parent
    return dir_comp.context, dir_comp
  elseif comp.name == "file" then
    local dir_comp = comp.parent.parent
    return dir_comp.context, dir_comp
  end
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  if self.listing_style == "list" then
    for _, file_list in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      for _, comp_struct in ipairs(file_list) do
        if file == comp_struct.comp.context then
          utils.set_cursor(self.winid, comp_struct.comp.lstart + 1, 0)
        end
      end
    end

  else -- tree
    for _, comp_struct in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      comp_struct.comp:deep_some(function(cur)
        if file == cur.context then
          local was_concealed = false
          local dir = cur.parent.parent

          while dir and dir.name == "directory" do
            if dir.context and dir.context.collapsed then
              was_concealed = true
              dir.context.collapsed = false
            end

            dir = utils.tbl_access(dir, { "parent", "parent" })
          end

          if was_concealed then
            self:render()
            self:redraw()
          end

          utils.set_cursor(self.winid, cur.lstart + 1, 0)
          return true
        end

        return false
      end)
    end
  end

  -- Needed to update the cursorline highlight when the panel is not focused.
  utils.update_win(self.winid)
end

function FilePanel:highlight_cur_file()
  if self.cur_file then
    self:highlight_file(self.cur_file)
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(
    api.nvim_win_set_cursor,
    self.winid,
    { self.constrain_cursor(self.winid, -vim.v.count1), 0 }
  )
  utils.update_win(self.winid)
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, vim.v.count1),
    0,
  })
  utils.update_win(self.winid)
end

function FilePanel:reconstrain_cursor()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, 0),
    0,
  })
end

---@param item DirData|any
---@param open boolean
function FilePanel:set_item_fold(item, open)
  if type(item.collapsed) == "boolean" and open == item.collapsed then
    item.collapsed = not open
    self:render()
    self:redraw()

    if item.collapsed then
      self.components.comp:deep_some(function(comp, _, _)
        if comp.context == item then
          utils.set_cursor(self.winid, comp.lstart + 1)
          return true
        end
      end)
    end
  end
end

function FilePanel:toggle_item_fold(item)
  self:set_item_fold(item, item.collapsed)
end

function FilePanel:save_fold_state()
  local state = {}
  if self.components and self.components.comp then
    self.components.comp:deep_some(function(comp)
      local ctx = comp.context
      if ctx and type(ctx.collapsed) == "boolean" and ctx.path then
        state[ctx.path] = ctx.collapsed
      end
    end)
  end
  return state
end

function FilePanel:restore_fold_state(state)
  if self.components and self.components.comp then
    self.components.comp:deep_some(function(comp)
      local ctx = comp.context
      if ctx and type(ctx.collapsed) == "boolean" and ctx.path then
        if state[ctx.path] ~= nil then
          ctx.collapsed = state[ctx.path]
        end
      end
    end)
  end
end

function FilePanel:save_cursor_position()
  if self:is_open() and self.winid and api.nvim_win_is_valid(self.winid) then
    return api.nvim_win_get_cursor(self.winid)
  end
end

function FilePanel:restore_cursor_position(pos)
  if pos and self:is_open() and self.winid and api.nvim_win_is_valid(self.winid) then
    local line_count = api.nvim_buf_line_count(self.bufid)
    local line = math.min(pos[1], line_count)
    pcall(api.nvim_win_set_cursor, self.winid, { line, pos[2] })
  end
end

---@param name "tests"|"generated"|"reviewed"
function FilePanel:toggle_filter(name)
  self.hidden[name] = not self.hidden[name]
  self:rebuild()
end

function FilePanel:rebuild()
  local cursor_pos = self:save_cursor_position()
  self:update_components()
  self:render()
  self:redraw()
  self:reconstrain_cursor()
  self:restore_cursor_position(cursor_pos)
end

function FilePanel:refresh_review()
  if self.hidden.reviewed then
    self:rebuild()
  else
    self:render()
    self:redraw()
  end
end

---@return { reviewed: integer, total: integer, additions: integer, deletions: integer, comments: integer, tests: integer, generated: integer }
function FilePanel:review_progress()
  local p = { reviewed = 0, total = 0, additions = 0, deletions = 0, comments = 0, tests = 0, generated = 0 }
  local paths = {}
  for _, file in self.files:iter() do
    local entry = paths[file.path]
    if not entry then
      entry = { kind = file.review_kind, counted = false, reviewed = true, comments = file.comments or 0 }
      paths[file.path] = entry
    end
    if self:counted(file) then
      entry.counted = true
      entry.reviewed = entry.reviewed and file.reviewed
      if file.stats and file.stats.additions then
        p.additions = p.additions + file.stats.additions
        p.deletions = p.deletions + file.stats.deletions
      end
    end
  end
  for _, entry in pairs(paths) do
    if entry.kind == "test" then
      p.tests = p.tests + 1
    elseif entry.kind == "generated" then
      p.generated = p.generated + 1
    end
    if entry.counted then
      p.total = p.total + 1
      p.comments = p.comments + entry.comments
      if entry.reviewed then
        p.reviewed = p.reviewed + 1
      end
    end
  end
  return p
end

function FilePanel:render()
  require("diffview.scene.views.diff.render")(self)
end

M.FilePanel = FilePanel
return M
