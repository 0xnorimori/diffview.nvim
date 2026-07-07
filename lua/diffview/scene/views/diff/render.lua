local config = require("diffview.config")
local hl = require("diffview.hl")
local utils = require("diffview.utils")

local pl = utils.path

local function count_reviewed_in_dir(items_comp)
  local reviewed = 0
  local total = 0
  for _, c in ipairs(items_comp.components) do
    if c.name == "file" then
      total = total + 1
      if c.context.reviewed then
        reviewed = reviewed + 1
      end
    elseif c.name == "directory" then
      local sub_items = c.components[2]
      if sub_items then
        local sub_reviewed, sub_total = count_reviewed_in_dir(sub_items)
        reviewed = reviewed + sub_reviewed
        total = total + sub_total
      end
    end
  end
  return reviewed, total
end

local function count_annotations_in_dir(items_comp, annot_store)
  local count = 0
  for _, c in ipairs(items_comp.components) do
    if c.name == "file" then
      count = count + annot_store:count_for_file(c.context.path)
    elseif c.name == "directory" then
      local sub_items = c.components[2]
      if sub_items then
        count = count + count_annotations_in_dir(sub_items, annot_store)
      end
    end
  end
  return count
end

---@param comp  RenderComponent
---@param show_path boolean
---@param depth integer|nil
---@param annot_store? AnnotationStore
local function render_file(comp, show_path, depth, annot_store)
  ---@type FileEntry
  local file = comp.context

  if file.reviewed then
    comp:add_text("✓", "DiffviewFilePanelReviewed")
  else
    comp:add_text(" ")
  end

  if annot_store then
    local ac = annot_store:count_for_file(file.path)
    if ac > 0 then
      comp:add_text(string.format("[%d]", ac), "DiffviewAnnotation")
    end
  end

  comp:add_text(file.status .. " ", hl.get_git_hl(file.status))

  if depth then
    comp:add_text(string.rep(" ", depth * 2 + 2))
  end

  local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
  comp:add_text(icon, icon_hl)
  comp:add_text(file.basename, file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName")

  if file.stats then
    if file.stats.additions then
      comp:add_text(" " .. file.stats.additions, "DiffviewFilePanelInsertions")
      comp:add_text(", ")
      comp:add_text(tostring(file.stats.deletions), "DiffviewFilePanelDeletions")
    elseif file.stats.conflicts then
      local has_conflicts = file.stats.conflicts > 0
      comp:add_text(
        " " .. (has_conflicts and file.stats.conflicts or config.get_config().signs.done),
        has_conflicts and "DiffviewFilePanelConflicts" or "DiffviewFilePanelInsertions"
      )
    end
  end

  if file.kind == "conflicting" and not (file.stats and file.stats.conflicts) then
    comp:add_text(" !", "DiffviewFilePanelConflicts")
  end

  if show_path then
    comp:add_text(" " .. file.parent_path, "DiffviewFilePanelPath")
  end

  comp:ln()
end

---@param comp RenderComponent
---@param annot_store? AnnotationStore
local function render_file_list(comp, annot_store)
  for _, file_comp in ipairs(comp.components) do
    render_file(file_comp, true, nil, annot_store)
  end
end

---@param ctx DirData
---@param tree_options TreeOptions
---@return string
local function get_dir_status_text(ctx, tree_options)
  local folder_statuses = tree_options.folder_statuses

  if folder_statuses == "always" or (folder_statuses == "only_folded" and ctx.collapsed) then
    return ctx.status
  end

  return " "
end

---@param depth integer
---@param comp RenderComponent
---@param annot_store? AnnotationStore
local function render_file_tree_recurse(depth, comp, annot_store)
  local conf = config.get_config()

  if comp.name == "file" then
    render_file(comp, false, depth, annot_store)
    return
  end

  if comp.name ~= "directory" then return end

  -- Directory component structure:
  -- {
  --   name = "directory",
  --   context = <DirData>,
  --   { name = "dir_name" },
  --   { name = "items", ...<files> },
  -- }

  local dir = comp.components[1]
  local items = comp.components[2]
  local ctx = comp.context --[[@as DirData ]]

  dir:add_text(
    get_dir_status_text(ctx, conf.file_panel.tree_options) .. " ",
    hl.get_git_hl(ctx.status)
  )
  dir:add_text(string.rep(" ", depth * 2))
  dir:add_text(ctx.collapsed and conf.signs.fold_closed or conf.signs.fold_open, "DiffviewNonText")

  if conf.use_icons then
    dir:add_text(
      " " .. (ctx.collapsed and conf.icons.folder_closed or conf.icons.folder_open) .. " ",
      "DiffviewFolderSign"
    )
  end

  dir:add_text(ctx.name, "DiffviewFolderName")

  local reviewed, total = count_reviewed_in_dir(items)
  if reviewed > 0 then
    dir:add_text(string.format(" (%d/%d)", reviewed, total), "DiffviewFilePanelReviewed")
  end

  if annot_store then
    local ac = count_annotations_in_dir(items, annot_store)
    if ac > 0 then
      dir:add_text(string.format(" [%d]", ac), "DiffviewAnnotation")
    end
  end

  dir:ln()

  if not ctx.collapsed then
    for _, item in ipairs(items.components) do
      render_file_tree_recurse(depth + 1, item, annot_store)
    end
  end
end

---@param comp RenderComponent
---@param annot_store? AnnotationStore
local function render_file_tree(comp, annot_store)
  for _, c in ipairs(comp.components) do
    render_file_tree_recurse(0, c, annot_store)
  end
end

---@param listing_style "list"|"tree"
---@param comp RenderComponent
---@param annot_store? AnnotationStore
local function render_files(listing_style, comp, annot_store)
  if listing_style == "list" then
    return render_file_list(comp, annot_store)
  end
  render_file_tree(comp, annot_store)
end

---@param panel FilePanel
return function(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()
  local conf = config.get_config()
  local width = panel:infer_width()
  local annot_store = panel.annot_store

  local comp = panel.components.path.comp

  comp:add_line(
    pl:truncate(pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~"), width - 6),
    "DiffviewFilePanelRootPath"
  )

  if conf.show_help_hints and panel.help_mapping then
    comp:add_text("Help: ", "DiffviewFilePanelPath")
    comp:add_line(panel.help_mapping, "DiffviewFilePanelCounter")
    comp:add_line()
  end

  if #panel.files.conflicting > 0 then
    comp = panel.components.conflicting.title.comp
    comp:add_text("Conflicts ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.conflicting .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    render_files(panel.listing_style, panel.components.conflicting.files.comp, annot_store)
    panel.components.conflicting.margin.comp:add_line()
  end

  local has_other_files = #panel.files.conflicting > 0 or #panel.files.staged > 0

  if #panel.files.working > 0 or not has_other_files then
    comp = panel.components.working.title.comp
    comp:add_text("Changes ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.working .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    render_files(panel.listing_style, panel.components.working.files.comp, annot_store)
    panel.components.working.margin.comp:add_line()
  end

  if #panel.files.staged > 0 then
    comp = panel.components.staged.title.comp
    comp:add_text("Staged changes ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.staged .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    render_files(panel.listing_style, panel.components.staged.files.comp, annot_store)
    panel.components.staged.margin.comp:add_line()
  end

  if panel.rev_pretty_name or (panel.path_args and #panel.path_args > 0) then
    local extra_info = utils.vec_join({ panel.rev_pretty_name }, panel.path_args or {})

    comp = panel.components.info.title.comp
    comp:add_line("Showing changes for:", "DiffviewFilePanelTitle")

    comp = panel.components.info.entries.comp

    for _, arg in ipairs(extra_info) do
      local relpath = pl:relative(arg, panel.adapter.ctx.toplevel)
      if relpath == "" then relpath = "." end
      comp:add_line(pl:truncate(relpath, width - 5), "DiffviewFilePanelPath")
    end
  end
end
