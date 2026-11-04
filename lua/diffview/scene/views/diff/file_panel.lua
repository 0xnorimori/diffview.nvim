local config = require("diffview.config")
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")
local Panel = require("diffview.ui.panel").Panel
local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree
local review = require("diffview.review.panel")
local api = vim.api

local chrome_ns = api.nvim_create_namespace("diffview_review_panel")
local chrome_group = api.nvim_create_augroup("diffview_review_panel", { clear = true })
local CHROME_KEYS = { "q", "<leader>b", "<leader>e", "zc", "zt", "zg", "zr", "gS", "]f", "[f" }
local M = {}

---@class TreeOptions
---@field flatten_dirs boolean
---@field group_dirs boolean
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
---@field hidden { code: boolean, tests: boolean, generated: boolean, reviewed: boolean }
---@field host? { send: function, meta: { subtitle: string?, base: string?, changes: string?, recipient: string?, sent: integer? } }
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
    code = filters.code.hidden,
    tests = filters.tests.hidden,
    generated = filters.generated.hidden,
    reviewed = filters.reviewed.hidden,
  }

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })

  self.focus_au = api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = chrome_group,
    callback = function(ev)
      if not self:is_open() then
        return
      end
      local cur = api.nvim_get_current_win()
      if cur == self.winid then
        vim.wo[self.winid].cursorline = ev.event == "WinEnter"
      elseif ev.event == "WinEnter" and (cur == self.header_win or cur == self.footer_win) then
        self:pass_focus(cur, vim.fn.win_getid(vim.fn.winnr("#")))
      end
    end,
  })

  self.resize_au = api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = chrome_group,
    callback = function(ev)
      if not self:is_open() then
        return
      end
      local mine = ev.event == "VimResized"
      for _, win in ipairs(mine and {} or vim.v.event.windows or {}) do
        if win == self.winid or win == self.header_win or win == self.footer_win then
          mine = true
        end
      end
      if mine then
        self:render()
        self:redraw()
      end
    end,
  })
end

---@override
function FilePanel:get_config()
  local conf = FilePanel.super_class.get_config(self)
  if not self.drawer then
    return conf
  end
  local top = vim.o.showtabline == 2 and 1 or 0
  local bottom = vim.o.cmdheight + (vim.o.laststatus > 0 and 1 or 0)
  return {
    type = "float",
    relative = "editor",
    row = top,
    col = 0,
    width = math.max(math.min(conf.width or 38, vim.o.columns - 2), 10),
    height = math.max(vim.o.lines - top - bottom, 3),
    zindex = 50,
    style = "minimal",
    border = { "", "", "", "│", "", "", "", "" },
    win_opts = conf.win_opts or {},
  }
end

---@override
function FilePanel:open()
  FilePanel.super_class.open(self)
  self:open_chrome()
  vim.cmd("wincmd =")
  self:highlight_cur_file()
end

---@override
function FilePanel:close()
  self:close_chrome()
  FilePanel.super_class.close(self)
end

---@override
function FilePanel:destroy()
  pcall(api.nvim_del_autocmd, self.resize_au)
  pcall(api.nvim_del_autocmd, self.focus_au)
  FilePanel.super_class.destroy(self)
  for _, buf in ipairs({ self.header_buf, self.footer_buf }) do
    if buf and api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
end

---@override
function FilePanel:window_count()
  if self.drawer then
    return 0
  end
  local n = 1
  for _, win in ipairs({ self.header_win, self.footer_win }) do
    if win and api.nvim_win_is_valid(win) then
      n = n + 1
    end
  end
  return n
end

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

function FilePanel:chrome_buf(name)
  local field = name .. "_buf"
  if self[field] and api.nvim_buf_is_valid(self[field]) then
    return self[field]
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "DiffviewFiles"
  pcall(api.nvim_buf_set_name, buf, ("diffview:///panels/%d/DiffviewReview%s"):format(require("diffview.ui.panel").Panel.next_uid(), name))
  local conf = config.get_config()
  local opt = { silent = true, nowait = true, buffer = buf }
  for _, mapping in ipairs(conf.keymaps.file_panel) do
    if vim.tbl_contains(CHROME_KEYS, mapping[2]) then
      vim.keymap.set(mapping[1], mapping[2], mapping[3], vim.tbl_extend("force", opt, mapping[4] or {}, { buffer = buf }))
    end
  end
  vim.keymap.set("n", "<cr>", function()
    self:activate_at_cursor()
  end, opt)
  vim.keymap.set("n", "<LeftRelease>", function()
    self:click()
  end, opt)
  vim.keymap.set("n", "<esc>", function()
    if self.drawer then
      self:close()
    end
  end, opt)
  self[field] = buf
  return buf
end

local RULE = "%#DiffviewReviewBorder#%{repeat('─', winwidth(0))}"

local chrome_winopts = {
  number = false,
  relativenumber = false,
  cursorline = false,
  list = false,
  wrap = false,
  spell = false,
  signcolumn = "no",
  foldcolumn = "0",
  colorcolumn = "",
  winfixheight = true,
  winfixwidth = true,
  winbar = "",
  scrolloff = 0,
}

function FilePanel:open_chrome()
  if not self:is_open() then
    return
  end
  self:chrome_buf("header")
  self:chrome_buf("footer")
  vim.wo[self.winid].cursorline = api.nvim_get_current_win() == self.winid
  self:render_chrome()
  local config_ = self:get_config()
  for _, part in ipairs({ { "header", "aboveleft" }, { "footer", "belowright" } }) do
    local name, dir = part[1], part[2]
    local field = name .. "_win"
    local lines = self[name .. "_lines"]
    if not valid_win(self[field]) then
      if config_.type == "float" then
        self[field] = api.nvim_open_win(self[name .. "_buf"], false, self:chrome_float(name))
      else
        api.nvim_win_call(self.winid, function()
          vim.cmd(("noautocmd %s %dsplit"):format(dir, math.max(#lines, 1)))
          self[field] = api.nvim_get_current_win()
        end)
        api.nvim_win_set_buf(self[field], self[name .. "_buf"])
      end
      utils.set_local(self[field], chrome_winopts)
      utils.set_local(self[field], { winhl = FilePanel.winopts.winhl })
    end
  end
  if config_.type == "float" then
    api.nvim_win_set_config(self.winid, self:chrome_float("tree"))
    for _, win in ipairs({ self.header_win, self.winid, self.footer_win }) do
      vim.wo[win].winhl = "Normal:DiffviewNormal,NormalFloat:DiffviewNormal,FloatBorder:DiffviewWinSeparator,"
        .. "EndOfBuffer:DiffviewEndOfBuffer,CursorLine:DiffviewCursorLine,SignColumn:DiffviewNormal"
    end
  else
    vim.wo[self.winid].winfixheight = false
    local rule = vim.o.laststatus == 3 and "" or RULE
    utils.set_local({ self.header_win, self.winid }, { statusline = rule })
  end
  api.nvim_create_autocmd("WinClosed", {
    group = chrome_group,
    pattern = tostring(self.winid),
    once = true,
    callback = function()
      vim.schedule(function()
        if not self:is_open() then
          self:close_chrome()
        end
      end)
    end,
  })
  self:redraw_chrome()
end

---@param win integer
---@param from integer
function FilePanel:pass_focus(win, from)
  self.chrome_from = from
  vim.schedule(function()
    if not (self:is_open() and api.nvim_get_current_win() == win) then
      return
    end
    if from ~= self.winid then
      api.nvim_set_current_win(self.winid)
    else
      vim.cmd(win == self.header_win and "wincmd W" or "wincmd w")
    end
  end)
end

function FilePanel:close_chrome()
  local wins = { self.header_win, self.footer_win }
  local cur = api.nvim_get_current_win()
  if vim.tbl_contains(wins, cur) and self:is_open() then
    api.nvim_set_current_win(self.winid)
  end
  for _, win in ipairs(wins) do
    if valid_win(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  self.header_win, self.footer_win = nil, nil
end

---@param name "header"|"tree"|"footer"
function FilePanel:chrome_float(name)
  local conf = self:get_config()
  local top = conf.row or 0
  local height = conf.height
  local header = #(self.header_lines or {})
  local footer = #(self.footer_lines or {})
  local spec = {
    relative = conf.relative or "editor",
    win = conf.relative == "win" and conf.win or nil,
    width = conf.width,
    col = conf.col or 0,
    zindex = conf.zindex or 50,
    style = "minimal",
    border = conf.border,
  }
  if name == "header" then
    spec.row, spec.height = top, math.max(header, 1)
  elseif name == "tree" then
    spec.row, spec.height = top + header, math.max(height - header - footer, 1)
  else
    spec.row, spec.height = top + height - footer, math.max(footer, 1)
  end
  return spec
end

function FilePanel:render_chrome()
  local width = self:infer_width()
  self.header_lines = review.header(self, width)
  self.footer_lines = review.footer(self, width, {
    jump = function(c)
      self:jump_to_comment(c)
    end,
    send = self.host and self.host.send or nil,
    copy = function()
      self:copy_comments()
    end,
  })
end

function FilePanel:redraw_chrome()
  review.write(self.header_buf, chrome_ns, self.header_lines or {})
  review.write(self.footer_buf, chrome_ns, self.footer_lines or {})
  if self:get_config().type == "float" then
    for _, name in ipairs({ "header", "tree", "footer" }) do
      local win = name == "tree" and self.winid or self[name .. "_win"]
      if valid_win(win) then
        api.nvim_win_set_config(win, self:chrome_float(name))
      end
    end
    return
  end
  for _, name in ipairs({ "header", "footer" }) do
    local win = self[name .. "_win"]
    if valid_win(win) then
      api.nvim_win_set_height(win, math.max(#self[name .. "_lines"], 1))
    end
  end
end

---@override
function FilePanel:redraw()
  FilePanel.super_class.redraw(self)
  self:redraw_chrome()
end

---@param winid integer
---@param row integer
---@param col integer 0-based byte column
---@return boolean
function FilePanel:activate(winid, row, col)
  local lines
  if winid == self.header_win then
    lines = self.header_lines
  elseif winid == self.footer_win then
    lines = self.footer_lines
  elseif winid == self.winid then
    local comp = self.components and self.components.comp:get_comp_on_line(row)
    if comp and comp.name == "hints" and comp.height > 0 then
      self:toggle_filter("reviewed")
      return true
    end
    return false
  end
  local action = lines and review.hit(lines, row, col)
  if action then
    action()
    return true
  end
  return false
end

---@return boolean
function FilePanel:activate_at_cursor()
  local win = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)
  return self:activate(win, cursor[1], cursor[2])
end

function FilePanel:click()
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or pos.line == 0 then
    return
  end
  local col = vim.fn.virtcol2col(pos.winid, pos.line, pos.column) - 1
  if pos.winid == self.winid then
    local comp = self.components and self.components.comp:get_comp_on_line(pos.line)
    if comp and (comp.name == "file" or comp.name == "dir_name") and self.view then
      api.nvim_win_set_cursor(self.winid, { pos.line, 0 })
      local item = self:get_item_at_cursor()
      if item and type(item.collapsed) == "boolean" then
        self:toggle_item_fold(item)
      elseif item then
        self.view:set_file(item, false)
      end
      return
    end
  end
  if pos.winid == self.header_win or pos.winid == self.footer_win then
    if valid_win(self.chrome_from) and self.chrome_from ~= pos.winid then
      api.nvim_set_current_win(self.chrome_from)
    else
      vim.cmd("wincmd p")
    end
  end
  self:activate(pos.winid, pos.line, col)
end

---@param c table
function FilePanel:jump_to_comment(c)
  local view = self.view
  if not view then
    return
  end
  local target
  for _, file in self.files:iter() do
    if file.path == c.file then
      target = file
      break
    end
  end
  if not target then
    return
  end
  local function place()
    local layout = view.cur_layout
    local win = c.side == "old" and layout.a or layout.b
    if not (win and win:is_valid()) then
      win = layout.b
    end
    if not (win and win:is_valid()) then
      return
    end
    local buf = api.nvim_win_get_buf(win.id)
    local row = math.max(1, math.min(c.line_start or 1, api.nvim_buf_line_count(buf)))
    api.nvim_set_current_win(win.id)
    pcall(api.nvim_win_set_cursor, win.id, { row, 0 })
  end
  if view.cur_entry == target and target.opened then
    place()
  else
    view.emitter:once("file_open_post", function()
      vim.schedule(place)
    end)
    view:set_file(target, false)
  end
end

function FilePanel:copy_comments()
  local ok, nrev = pcall(require, "nrev")
  if not ok then
    return
  end
  nrev.export(self.adapter.ctx.toplevel)
end

function FilePanel:setup_buffer()
  local conf = config.get_config()
  vim.keymap.set("n", "<esc>", function()
    if self.drawer then
      self:close()
    end
  end, { silent = true, nowait = true, buffer = self.bufid })
  vim.keymap.set("n", "<LeftRelease>", function()
    self:click()
  end, { silent = true, nowait = true, buffer = self.bufid })

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
  return not self.hidden.code
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
  self.shown = {}
  self.visible_trees = {}
  for _, kind in ipairs({ "conflicting", "working", "staged" }) do
    self.visible[kind] = vim.tbl_filter(function(file)
      return self:visible_file(file)
    end, self.files[kind])
    self.shown[kind] = vim.tbl_filter(function(file)
      return self:counted(file)
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
      self.visible_trees[kind] = FileTree(self.shown[kind], self.tree_options.group_dirs)
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

---@return integer[]
function FilePanel:buffers()
  return vim.tbl_filter(function(buf)
    return buf ~= nil and api.nvim_buf_is_valid(buf)
  end, { self.header_buf, self.bufid, self.footer_buf })
end

---@param files FileEntry[]
---@return FileEntry[]
function FilePanel:sorted(files)
  if self.listing_style == "list" then
    return files
  end
  local tree = FileTree(files, self.tree_options.group_dirs)
  tree.root:sort()
  return vim.tbl_map(function(node)
    return node.data
  end, tree.root:leaves())
end

---@param dir 1|-1
---@param cur FileEntry?
---@return FileEntry?
function FilePanel:next_unreviewed(dir, cur)
  local files = self:ordered_file_list()
  local n = #files
  if n == 0 then
    return
  end
  local start = utils.vec_indexof(files, cur)
  if start == -1 then
    start = dir > 0 and 0 or n + 1
    if cur then
      local before = 0
      local visible = {}
      for _, file in ipairs(files) do
        visible[file] = true
      end
      for _, kind in ipairs({ "conflicting", "working", "staged" }) do
        for _, file in ipairs(self:sorted(self.files[kind])) do
          if file == cur then
            start = dir > 0 and before or before + 1
          elseif visible[file] then
            before = before + 1
          end
        end
      end
    end
  end
  for i = 1, n do
    local file = files[(start - 1 + i * dir) % n + 1]
    if not file.reviewed then
      return file
    end
  end
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

    return vim.tbl_filter(function(file)
      return self:visible_file(file)
    end, vim.tbl_map(function(node)
      return node.data
    end, nodes)) --[[@as vector ]]
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

---@param name "code"|"tests"|"generated"|"reviewed"
function FilePanel:toggle_filter(name)
  self.hidden[name] = not self.hidden[name]
  self:rebuild()
end

---@param name "code"|"tests"|"generated"|"reviewed"
---@param hidden boolean
function FilePanel:set_filter(name, hidden)
  if self.hidden[name] == nil then
    error("unknown filter: " .. tostring(name), 0)
  end
  if self.hidden[name] ~= hidden then
    self:toggle_filter(name)
  end
end

---@return table<string, { shown: boolean, count: integer }>
function FilePanel:filters()
  local p = self:review_progress()
  local counts = { code = p.code, tests = p.tests, generated = p.generated, reviewed = p.reviewed }
  local ret = {}
  for name, count in pairs(counts) do
    ret[name] = { shown = not self.hidden[name], count = count }
  end
  return ret
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

---@return { reviewed: integer, total: integer, additions: integer, deletions: integer, comments: integer, code: integer, tests: integer, generated: integer }
function FilePanel:review_progress()
  local p = { reviewed = 0, total = 0, additions = 0, deletions = 0, comments = 0, code = 0, tests = 0, generated = 0 }
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
      local additions, deletions = review.stats(file)
      if additions then
        p.additions = p.additions + additions
        p.deletions = p.deletions + deletions
      end
    end
  end
  for _, entry in pairs(paths) do
    if entry.kind == "test" then
      p.tests = p.tests + 1
    elseif entry.kind == "generated" then
      p.generated = p.generated + 1
    else
      p.code = p.code + 1
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
  self:render_chrome()
end

M.FilePanel = FilePanel
return M
