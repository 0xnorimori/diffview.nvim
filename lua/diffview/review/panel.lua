local api = vim.api

local M = {}

M.MAX_COMMENTS = 3

local Line = {}
Line.__index = Line

function M.line()
  return setmetatable({ text = "", hls = {}, clicks = {} }, Line)
end

---@param text string
---@param hl string?
---@param action function?
function Line:add(text, hl, action)
  local first = #self.text
  self.text = self.text .. text
  if hl then
    table.insert(self.hls, { hl, first, #self.text })
  end
  if action then
    table.insert(self.clicks, { first, #self.text, action })
  end
  return self
end

function Line:width()
  return api.nvim_strwidth(self.text)
end

function Line:fill(hl, from, to)
  table.insert(self.hls, 1, { hl, from or 0, to or #self.text })
  return self
end

---@param parts { [1]: string, [2]: string?, [3]: function? }[]
---@param width integer
function Line:right(parts, width)
  local w = 0
  for _, part in ipairs(parts) do
    w = w + api.nvim_strwidth(part[1])
  end
  self:add(string.rep(" ", math.max(width - self:width() - w, 1)))
  for _, part in ipairs(parts) do
    self:add(part[1], part[2], part[3])
  end
  return self
end

---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
  if width <= 0 then
    return ""
  end
  if api.nvim_strwidth(text) <= width then
    return text
  end
  local chars = vim.fn.split(text, "\\zs")
  local out, w = {}, 0
  for _, ch in ipairs(chars) do
    local cw = api.nvim_strwidth(ch)
    if w + cw > width - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. "…"
end

---@param path string
---@param width integer
---@return string
function M.truncate_path(path, width)
  if api.nvim_strwidth(path) <= width then
    return path
  end
  local parts = vim.split(path, "/", { plain = true })
  if #parts > 3 then
    local short = parts[1] .. "/" .. parts[2] .. "/…/" .. parts[#parts]
    if api.nvim_strwidth(short) <= width then
      return short
    end
    return M.truncate(short, width)
  end
  return M.truncate(path, width)
end

---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    if cur == "" then
      cur = word
    elseif api.nvim_strwidth(cur) + 1 + api.nvim_strwidth(word) <= width then
      cur = cur .. " " .. word
    else
      lines[#lines + 1] = cur
      cur = word
    end
  end
  if cur ~= "" then
    lines[#lines + 1] = cur
  end
  return lines
end

local MAX_COUNT_BYTES = 1048576

---@param path string
---@return integer
function M.line_count(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then
    return stat and stat.type == "link" and 1 or 0
  end
  local flags = bit.bor(vim.uv.constants.O_RDONLY or 0, vim.uv.constants.O_NONBLOCK or 0)
  local fd = vim.uv.fs_open(path, flags, 0)
  if not fd then
    return 0
  end
  local fstat = vim.uv.fs_fstat(fd)
  local data = fstat and fstat.type == "file" and vim.uv.fs_read(fd, MAX_COUNT_BYTES, 0) or ""
  vim.uv.fs_close(fd)
  if data == "" or data:find("\0", 1, true) then
    return 0
  end
  local _, n = data:gsub("\n", "")
  return data:sub(-1) == "\n" and n or n + 1
end

---@param file FileEntry
---@return integer?, integer?
function M.stats(file)
  local stats = file.stats
  if stats and stats.additions then
    return stats.additions, stats.deletions
  end
  if file.status == "?" and file.absolute_path then
    local stat = vim.uv.fs_lstat(file.absolute_path)
    local key = stat and (stat.mtime.sec .. ":" .. stat.mtime.nsec .. ":" .. stat.size) or ""
    if file._review_count_key ~= key then
      file._review_count_key = key
      file._review_count = M.line_count(file.absolute_path)
    end
    return file._review_count, 0
  end
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

M.plural = plural

local function border(width)
  return M.line():add(string.rep("─", width), "DiffviewReviewBorder")
end

local function key(l, k)
  return l:add(" " .. k .. " ", "DiffviewReviewKey")
end

---@param panel FilePanel
---@return integer
function M.open_comments(panel)
  if panel.comments then
    local n = 0
    for _, c in ipairs(panel.comments) do
      if c.status == "open" then
        n = n + 1
      end
    end
    return n
  end
  local n = 0
  for _, file in panel.files:iter() do
    n = n + (file.comments or 0)
  end
  return n
end

---@param panel FilePanel
---@return string
function M.subtitle(panel)
  local meta = panel.host and panel.host.meta or {}
  if meta.subtitle and meta.subtitle ~= "" then
    return meta.subtitle
  end
  local name = vim.fn.fnamemodify(panel.adapter.ctx.toplevel, ":t")
  if panel.rev_pretty_name and panel.rev_pretty_name ~= "" then
    return name .. " · " .. panel.rev_pretty_name
  end
  return name
end

---@param p table
---@return boolean
function M.is_done(p)
  return p.total > 0 and p.reviewed == p.total
end

local filter_items = {
  { name = "code", label = "code" },
  { name = "tests", label = "tests", count = "tests" },
  { name = "generated", label = "generated", count = "generated" },
}

local function checkbox(l, panel, name, label)
  local on = not panel.hidden[name]
  local toggle = function()
    panel:toggle_filter(name)
  end
  local glyphs = require("diffview.config").get_config().file_panel.checkbox
  l:add(on and glyphs.on or glyphs.off, on and "DiffviewReviewCheckOn" or "DiffviewReviewCheckOff", toggle)
  l:add(" " .. label, on and "DiffviewReviewText" or "DiffviewReviewMuted", toggle)
end

---@param panel FilePanel
---@param width integer
function M.header(panel, width)
  local p = panel:review_progress()
  local meta = panel.host and panel.host.meta or {}
  local inner = width - 2
  local done = M.is_done(p)
  local lines = {}

  local title = M.line():add(" "):add("Review", "DiffviewReviewTitle")
  local subtitle = M.subtitle(panel)
  if subtitle ~= "" then
    title:add(" " .. M.truncate(subtitle, inner - 7), "DiffviewReviewMuted")
  end
  lines[#lines + 1] = title

  local counter = ("%d / %d"):format(p.reviewed, p.total)
  local bar = math.max(inner - api.nvim_strwidth(counter .. " reviewed") - 2, 4)
  local filled = p.total > 0 and math.floor(bar * p.reviewed / p.total + 0.5) or 0
  lines[#lines + 1] = M.line()
    :add(" ")
    :add(string.rep("━", filled), done and "DiffviewReviewBarDone" or "DiffviewReviewBar")
    :add(string.rep("━", bar - filled), "DiffviewReviewBarTodo")
    :right({ { counter, "DiffviewReviewCounter" }, { " reviewed", "DiffviewReviewText" } }, width - 1)

  local open = M.open_comments(panel)
  local stats = M.line()
    :add(" ")
    :add("+" .. p.additions, "DiffviewReviewSuccess")
    :add(" ")
    :add("−" .. p.deletions, "DiffviewReviewDanger")
    :add(" · ", "DiffviewReviewMuted")
  if open > 0 then
    stats:add(plural(open, "open comment"), "DiffviewReviewWarning")
  else
    stats:add("no comments", "DiffviewReviewMuted")
  end
  lines[#lines + 1] = stats

  local function filter_line(items, lead)
    for _, sep in ipairs({ "  ", " " }) do
      local l = M.line():add(" ")
      if lead then
        l:add(lead .. sep, "DiffviewReviewMuted")
      end
      for i, item in ipairs(items) do
        if i > 1 then
          l:add(sep)
        end
        checkbox(l, panel, item.name, item.count and (item.label .. " " .. p[item.count]) or item.label)
      end
      if l:width() <= width - 1 or sep == " " then
        return l
      end
    end
  end
  lines[#lines + 1] = filter_line(filter_items, "Show")
  lines[#lines + 1] = filter_line({ { name = "reviewed", label = "reviewed" } })

  if done then
    local text
    if (meta.sent or 0) > 0 then
      text = ("✓ %d/%d · %s sent"):format(p.total, p.total, plural(meta.sent, "comment"))
    else
      text = "✓ All " .. plural(p.total, "file") .. " reviewed"
      if open > 0 then
        text = text .. " · " .. plural(open, "comment") .. (meta.recipient and (" for " .. meta.recipient) or "")
      end
    end
    for _, row in ipairs(M.wrap(text, inner - 2)) do
      local l = M.line():add(" ")
      local first = #l.text
      l:add(" " .. row .. string.rep(" ", inner - 1 - api.nvim_strwidth(row)))
      l:fill("DiffviewReviewDone", first, #l.text)
      lines[#lines + 1] = l
    end
  end

  if panel.drawer then
    lines[#lines + 1] = border(width)
  end
  return lines
end

local type_hls = {
  issue = "DiffviewReviewWarning",
  praise = "DiffviewReviewSuccess",
}

local type_icons = { issue = "●", suggestion = "◆", question = "?", note = "·", praise = "+" }

---@param comments table[]
---@return table[]
function M.order_comments(comments)
  local list = vim.deepcopy(comments or {})
  table.sort(list, function(a, b)
    local ao, bo = a.status == "open", b.status == "open"
    if ao ~= bo then
      return ao
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return (a.line_start or 0) < (b.line_start or 0)
  end)
  return list
end

local function first_line(text)
  return ((text or ""):gsub("\n.*", ""))
end

---@param panel FilePanel
---@param width integer
---@param actions { jump: fun(c: table), send: function?, copy: function }
function M.footer(panel, width, actions)
  local p = panel:review_progress()
  local lines = { panel.drawer and border(width) or nil }
  local comments = M.order_comments(panel.comments)

  if #comments > 0 then
    local open = M.open_comments(panel)
    local toggle = function()
      panel.comments_collapsed = not panel.comments_collapsed
      panel:render_chrome()
    end
    local head = M.line()
      :add(" ")
      :add(panel.comments_collapsed and "›" or "⌄", "DiffviewReviewMuted", toggle)
      :add(" Comments", "DiffviewReviewText", toggle)
      :add(" · " .. open .. " open", "DiffviewReviewMuted", toggle)
    key(head:right({}, width - 6), ",rl")
    lines[#lines + 1] = head

    if not panel.comments_collapsed then
      for i, c in ipairs(comments) do
        if i > M.MAX_COMMENTS then
          lines[#lines + 1] = M.line():add("   + " .. (#comments - M.MAX_COMMENTS) .. " more · ,rl lists all", "DiffviewReviewMuted")
          break
        end
        local jump = function()
          actions.jump(c)
        end
        local resolved = c.status ~= "open"
        local where = ("%s:%d"):format(vim.fn.fnamemodify(c.file, ":t"), c.line_start or 0)
        local meta = resolved and (c.type .. " · resolved · " .. where) or (c.type .. " · " .. where)
        lines[#lines + 1] = M.line()
          :add(" ")
          :add(resolved and "✓" or (type_icons[c.type] or "●"), resolved and "DiffviewReviewResolved" or (type_hls[c.type] or "DiffviewReviewMuted"), jump)
          :add(" " .. M.truncate(meta, width - 4), resolved and "DiffviewReviewResolved" or "DiffviewReviewMuted", jump)
        lines[#lines + 1] = M.line()
          :add("   ")
          :add(M.truncate(first_line(c.text), width - 4), resolved and "DiffviewReviewResolved" or "DiffviewReviewText", jump)
      end
    end
    lines[#lines + 1] = border(width)
  end

  for _, row in ipairs({ { { "r", "reviewed" }, { "]f", "next to review" } }, { { ",rc", "comment" }, { "]a", "next comment" } } }) do
    local l = M.line():add(" ")
    for i, k in ipairs(row) do
      if i > 1 then
        l:add("  ")
      end
      key(l, k[1])
      l:add(" " .. k[2], "DiffviewReviewMuted")
    end
    lines[#lines + 1] = l
  end

  local buttons = M.line():add(" ")
  if actions.send then
    local open = M.open_comments(panel)
    local label = open > 0 and ("Send " .. plural(open, "comment")) or "Send review"
    local hl = M.is_done(p) and "DiffviewReviewButtonPrimary" or "DiffviewReviewButton"
    buttons:add(" " .. label .. " ⌘↩ ", hl, actions.send)
  end
  buttons:right({ { "Copy", "DiffviewReviewText", actions.copy }, { " " }, { " ,re ", "DiffviewReviewKey", actions.copy } }, width - 1)
  lines[#lines + 1] = buttons
  lines[#lines + 1] = border(width)

  local legend = {
    { { "○", "to review", "DiffviewReviewFaint" }, { "✓", "reviewed", "DiffviewReviewSuccess" } },
    { { "●", "changed since", "DiffviewReviewWarning" }, { "n", "comments", "DiffviewReviewWarning" } },
  }
  for _, row in ipairs(legend) do
    local l = M.line():add(" ")
    for i, item in ipairs(row) do
      l:add(i > 1 and "  " or "")
      l:add(item[1], item[3]):add(" " .. item[2], "DiffviewReviewMuted")
    end
    lines[#lines + 1] = l
  end

  return lines
end

---@param bufid integer
---@param ns integer
---@param lines table[]
function M.write(bufid, ns, lines)
  if not (bufid and api.nvim_buf_is_loaded(bufid)) then
    return
  end
  vim.bo[bufid].modifiable = true
  api.nvim_buf_set_lines(bufid, 0, -1, false, vim.tbl_map(function(l)
    return l.text
  end, lines))
  vim.bo[bufid].modifiable = false
  api.nvim_buf_clear_namespace(bufid, ns, 0, -1)
  for i, l in ipairs(lines) do
    for _, h in ipairs(l.hls) do
      api.nvim_buf_set_extmark(bufid, ns, i - 1, h[2], { end_col = h[3], hl_group = h[1] })
    end
  end
end

---@param lines table[]
---@param row integer 1-based
---@param col integer 0-based byte column
---@return function?
function M.hit(lines, row, col)
  local l = lines[row]
  for _, c in ipairs(l and l.clicks or {}) do
    if col >= c[1] and col < c[2] then
      return c[3]
    end
  end
end

return M
