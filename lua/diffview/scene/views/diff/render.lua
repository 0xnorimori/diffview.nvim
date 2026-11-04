local config = require("diffview.config")
local review = require("diffview.review.panel")
local utils = require("diffview.utils")

local api = vim.api
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

local function count_comments_in_dir(items_comp)
  local count = 0
  for _, c in ipairs(items_comp.components) do
    if c.name == "file" then
      count = count + (c.context.comments or 0)
    elseif c.name == "directory" then
      local sub_items = c.components[2]
      if sub_items then
        count = count + count_comments_in_dir(sub_items)
      end
    end
  end
  return count
end

local function strwidth(parts)
  local w = 0
  for _, part in ipairs(parts) do
    w = w + api.nvim_strwidth(part[1])
  end
  return w
end

---@param comp RenderComponent
---@param left { [1]: string, [2]: string?, flex: boolean?, path: boolean? }[]
---@param right { [1]: string, [2]: string? }[]
---@param width integer
---@param line_hl string?
local function add_row(comp, left, right, width, line_hl)
  local fixed = strwidth(right)
  for _, part in ipairs(left) do
    if not part.flex then
      fixed = fixed + api.nvim_strwidth(part[1])
    end
  end
  local room = width - 1 - fixed - (#right > 0 and 1 or 0)
  local start = #comp.line_buffer
  local w = 0
  for _, part in ipairs(left) do
    local text = part[1]
    if part.flex then
      text = part.path and review.truncate_path(text, room) or review.truncate(text, room)
      room = room - api.nvim_strwidth(text)
    end
    comp:add_text(text, part[2])
    w = w + api.nvim_strwidth(text)
  end
  if #right > 0 then
    local gap = math.max(width - 1 - w - strwidth(right), 1)
    comp:add_text(string.rep(" ", gap))
    w = w + gap
    for _, part in ipairs(right) do
      comp:add_text(part[1], part[2])
    end
    w = w + strwidth(right)
  end
  if line_hl then
    comp:add_text(string.rep(" ", math.max(width - w, 0)))
    table.insert(comp.hl, 1, { group = line_hl, line_idx = #comp.lines, first = start, last = #comp.line_buffer })
  end
  comp:ln()
end

local kind_chips = {
  A = { " new ", "DiffviewReviewChipNew" },
  ["?"] = { " new ", "DiffviewReviewChipNew" },
  D = { " deleted ", "DiffviewReviewChipDeleted" },
  R = { " renamed ", "DiffviewReviewChip" },
}

---@param comp RenderComponent
---@param show_path boolean
---@param depth integer
---@param width integer
local function render_file(comp, show_path, depth, width, panel)
  ---@type FileEntry
  local file = comp.context
  if panel and not panel:visible_file(file) then
    return
  end
  local left = {
    file.active and { "▎", "DiffviewReviewActiveBar" } or { " " },
    { string.rep(" ", depth * 2) },
  }

  if file.reviewed then
    table.insert(left, { "✓", "DiffviewReviewSuccess" })
  elseif file.stale then
    table.insert(left, { "●", "DiffviewReviewWarning" })
  else
    table.insert(left, { "○", "DiffviewReviewFaint" })
  end
  table.insert(left, { " " })
  table.insert(left, { file.basename, "DiffviewReviewText", flex = true })
  if show_path and file.parent_path ~= "" then
    table.insert(left, { " " .. file.parent_path, "DiffviewReviewMuted", flex = true })
  end

  local right = {}
  local chip = kind_chips[file.status]
  if chip then
    table.insert(right, chip)
    table.insert(right, { " " })
  end
  if (file.comments or 0) > 0 then
    table.insert(right, { " " .. file.comments .. " ", "DiffviewReviewCount" })
    table.insert(right, { " " })
  end
  local additions, deletions = review.stats(file)
  if additions then
    table.insert(right, { "+" .. additions, "DiffviewReviewSuccess" })
    table.insert(right, { " " })
    table.insert(right, { "−" .. deletions, "DiffviewReviewDanger" })
  elseif file.stats and file.stats.conflicts then
    local has_conflicts = file.stats.conflicts > 0
    table.insert(right, {
      has_conflicts and tostring(file.stats.conflicts) or config.get_config().signs.done,
      has_conflicts and "DiffviewFilePanelConflicts" or "DiffviewReviewSuccess",
    })
  elseif file.kind == "conflicting" then
    table.insert(right, { "!", "DiffviewFilePanelConflicts" })
  end
  if right[#right] and right[#right][1] == " " then
    table.remove(right)
  end

  add_row(comp, left, right, width, file.active and "DiffviewReviewActive" or nil)
end

---@param depth integer
---@param comp RenderComponent
---@param width integer
local function render_file_tree_recurse(depth, comp, width, panel)
  if comp.name == "file" then
    render_file(comp, false, depth, width, panel)
    return
  end

  if comp.name ~= "directory" then return end

  local dir = comp.components[1]
  local items = comp.components[2]
  local ctx = comp.context --[[@as DirData ]]

  local reviewed, total = count_reviewed_in_dir(items)
  local comments = count_comments_in_dir(items)
  local right = {}
  if comments > 0 then
    table.insert(right, { " " .. comments .. " ", "DiffviewReviewCount" })
    table.insert(right, { " " })
  end
  table.insert(right, { ("%d/%d"):format(reviewed, total), "DiffviewReviewMuted" })

  add_row(dir, {
    { " " .. string.rep(" ", depth * 2) },
    { ctx.collapsed and "›" or "⌄", "DiffviewReviewMuted" },
    { " " },
    { ctx.name, "DiffviewReviewFolder", flex = true, path = true },
  }, right, width)

  if not ctx.collapsed then
    for _, item in ipairs(items.components) do
      render_file_tree_recurse(depth + 1, item, width, panel)
    end
  end
end

---@param panel FilePanel
---@param comp RenderComponent
---@param width integer
local function render_files(panel, comp, width)
  if panel.listing_style == "list" then
    for _, file_comp in ipairs(comp.components) do
      render_file(file_comp, true, 0, width)
    end
    return
  end
  for _, c in ipairs(comp.components) do
    render_file_tree_recurse(0, c, width, panel)
  end
end

local function hidden_note(panel, p)
  local parts = {}
  if panel.hidden.tests and p.tests > 0 then
    parts[#parts + 1] = "tests"
  end
  if panel.hidden.generated and p.generated > 0 then
    parts[#parts + 1] = "generated files"
  end
  if #parts == 0 then
    return nil
  end
  local text = table.concat(parts, " and ")
  return text:sub(1, 1):upper() .. text:sub(2) .. " are hidden."
end

---@param comp RenderComponent
---@param panel FilePanel
---@param width integer
local function render_tip(comp, panel, width)
  local p = panel:review_progress()
  if p.reviewed > 0 or p.total == 0 or #(panel.comments or {}) > 0 or review.open_comments(panel) > 0 then
    return
  end
  local text = "Read a file, press r to mark it reviewed; ]f opens the next one."
  local note = hidden_note(panel, p)
  if note then
    text = text .. " " .. note
  end
  for i, row in ipairs(review.wrap(text, width - 4)) do
    comp:add_text(i == 1 and " › " or "   ", "DiffviewReviewMuted")
    local start = #comp.line_buffer
    comp:add_text(row, "DiffviewReviewMuted")
    for _, key in ipairs({ "r", "]f" }) do
      local from = 1
      while true do
        local s, e = row:find(key, from, true)
        if not s then break end
        local before = s == 1 and " " or row:sub(s - 1, s - 1)
        local after = row:sub(e + 1, e + 1)
        if before == " " and (after == " " or after == "") then
          comp:add_hl("DiffviewReviewKey", #comp.lines, start + s - 1, start + e)
        end
        from = e + 1
      end
    end
    comp:ln()
  end
  comp:add_line()
end

---@param panel FilePanel
return function(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()
  local width = panel:infer_width()
  local visible = panel.visible

  render_tip(panel.components.path.comp, panel, width)

  local listed = panel.listing_style == "tree" and panel.shown or visible
  local sections = 0
  for _, kind in ipairs({ "conflicting", "working", "staged" }) do
    if #listed[kind] > 0 then
      sections = sections + 1
    end
  end
  local titles = { conflicting = "Conflicts", working = "Changes", staged = "Staged changes" }

  for _, kind in ipairs({ "conflicting", "working", "staged" }) do
    if #listed[kind] > 0 then
      if sections > 1 then
        local comp = panel.components[kind].title.comp
        comp:add_text(" " .. titles[kind] .. " ", "DiffviewReviewTitle")
        comp:add_text(tostring(#visible[kind]), "DiffviewReviewMuted")
        comp:ln()
      end
      render_files(panel, panel.components[kind].files.comp, width)
      if sections > 1 then
        panel.components[kind].margin.comp:add_line()
      end
    end
  end

  if sections == 0 then
    panel.components.working.title.comp:add_line(
      panel.files:len() > 0 and " Every file is hidden by a filter" or " No changes",
      "DiffviewReviewMuted"
    )
  end

  if not panel.host and panel.path_args and #panel.path_args > 0 then
    local comp = panel.components.info.title.comp
    comp:add_line()
    comp:add_line(" Showing changes for:", "DiffviewReviewMuted")
    comp = panel.components.info.entries.comp
    for _, arg in ipairs(panel.path_args) do
      local relpath = pl:relative(arg, panel.adapter.ctx.toplevel)
      if relpath == "" then relpath = "." end
      comp:add_line(" " .. pl:truncate(relpath, width - 5), "DiffviewReviewMuted")
    end
  end

  local p = panel:review_progress()
  local hidden = 0
  if panel.hidden.reviewed then
    for _, file in panel.files:iter() do
      if file.reviewed and panel:counted(file) then
        hidden = hidden + 1
      end
    end
  end
  if hidden > 0 and p.total > 0 then
    local comp = panel.components.hints.comp
    comp:add_text(" " .. review.plural(hidden, "reviewed file") .. " hidden · ", "DiffviewReviewMuted")
    comp:add_text("show", "DiffviewReviewLink")
    comp:ln()
  end
end
