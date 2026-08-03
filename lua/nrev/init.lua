local M = {}

local ns = vim.api.nvim_create_namespace("nrev")
local types = { "issue", "suggestion", "question", "note", "praise" }
local icons = { issue = "●", suggestion = "◆", question = "?", note = "·", praise = "+" }
local hls = {
  issue = "DiagnosticError",
  suggestion = "DiagnosticInfo",
  question = "DiagnosticWarn",
  note = "DiagnosticHint",
  praise = "DiagnosticOk",
}

local config = { bin = nil }
local warned = false

local function default_bin()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(src)))
  return root .. "/bin/nrev"
end

local function bin()
  local b = config.bin or default_bin()
  if vim.fn.executable(b) == 1 then
    return b
  end
  if vim.fn.executable("nrev") == 1 then
    return "nrev"
  end
  if not warned then
    warned = true
    vim.notify("nrev binary not found — run :Lazy build diffview.nvim", vim.log.levels.WARN)
  end
  return nil
end

local queue = {}
local running = false

local function process_queue()
  if running or #queue == 0 then
    return
  end
  running = true
  local item = table.remove(queue, 1)
  local ok, err = pcall(vim.system, item.cmd, { cwd = item.cwd, text = true }, function(out)
    running = false
    vim.schedule(function()
      if item.cb then
        local cb_ok, cb_err = pcall(item.cb, out)
        if not cb_ok then
          vim.notify("nrev: " .. tostring(cb_err), vim.log.levels.ERROR)
        end
      end
      process_queue()
    end)
  end)
  if not ok then
    running = false
    vim.notify("nrev: " .. tostring(err), vim.log.levels.ERROR)
    vim.schedule(process_queue)
  end
end

function M.run(args, cwd, cb)
  local b = bin()
  if not b then
    return
  end
  local cmd = { b }
  vim.list_extend(cmd, args)
  table.insert(queue, { cmd = cmd, cwd = cwd, cb = cb })
  process_queue()
end

local toplevel_cache = {}

local function toplevel_for(gitdir)
  local cached = toplevel_cache[gitdir]
  if cached ~= nil then
    return cached
  end
  local top = gitdir:match("^(.*)/%.git$")
  if not top then
    local f = io.open(gitdir .. "/gitdir", "r")
    if f then
      local line = f:read("*l")
      f:close()
      if line and line ~= "" then
        top = vim.fs.dirname(line)
      end
    end
  end
  toplevel_cache[gitdir] = top or false
  return top or false
end

local function buf_info(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local gitdir, rest = name:match("^diffview://(.-/%.git)(/.*)$")
  if gitdir then
    local wt = rest:match("^(/worktrees/[^/]+)/")
    if wt then
      gitdir = gitdir .. wt
      rest = rest:sub(#wt + 1)
    end
    local rev, rel = rest:match("^/([^/]+)/(.+)$")
    local rev_ok = rev and ((rev:match("^%x+$") and #rev >= 7 and #rev <= 40) or rev:match("^:%d:$"))
    if rev_ok then
      local top = toplevel_for(gitdir)
      if top then
        return { file = rel, cwd = top, side = "old", rev = rev }
      end
    end
    return nil
  end
  if name:match("^%w+://") then
    return nil
  end
  return { file = name, cwd = vim.fs.dirname(name), side = "new", rev = "WORKING" }
end

local function render(bufnr, comments)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local rows = {}
  for _, c in ipairs(comments) do
    local row = math.min(c.line_start, count) - 1
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local drifted = c.status == "open" and line ~= c.line_text
    local head
    if c.status == "resolved" then
      head = { { ("✓ %s resolved"):format(c.type), "Comment" } }
    else
      local hl = hls[c.type] or "DiagnosticInfo"
      head = { { ("%s %s%s"):format(icons[c.type] or "●", c.type, drifted and " ⚠" or ""), hl } }
    end
    local virt = { head, { { "  " .. c.text, "Normal" } } }
    if c.resolution and c.resolution ~= vim.NIL then
      table.insert(virt, { { "  ↳ " .. c.resolution, "Comment" } })
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      sign_text = c.status == "resolved" and "✓" or (icons[c.type] or "●"),
      sign_hl_group = c.status == "resolved" and "Comment" or (hls[c.type] or "DiagnosticInfo"),
      virt_lines = virt,
    })
    table.insert(rows, {
      row = row + 1,
      row_end = math.min(c.line_end, count),
      id = c.id,
      status = c.status,
    })
  end
  vim.b[bufnr].nrev_comments = rows
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local info = buf_info(bufnr)
  if not info then
    return
  end
  M.run({ "list", "--json", "--status", "all", "--file", info.file }, info.cwd, function(out)
    if out.code ~= 0 or not out.stdout or out.stdout == "" then
      return
    end
    local ok, comments = pcall(vim.json.decode, out.stdout)
    if not ok or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local visible = {}
    for _, c in ipairs(comments) do
      if (info.side == "new" and c.side == "new") or (info.side == "old" and c.side == "old" and c.rev == info.rev) then
        table.insert(visible, c)
      end
    end
    render(bufnr, visible)
  end)
end

function M.add()
  local bufnr = vim.api.nvim_get_current_buf()
  local info = buf_info(bufnr)
  if not info then
    return
  end
  local s, e = vim.fn.line("."), vim.fn.line(".")
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    s, e = vim.fn.line("v"), vim.fn.line(".")
    if s > e then
      s, e = e, s
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end
  vim.ui.select(types, { prompt = "Comment type" }, function(typ)
    if not typ then
      return
    end
    vim.ui.input({ prompt = typ .. ": " }, function(text)
      if not text or text == "" then
        return
      end
      local line_text = vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1] or ""
      M.run({
        "add",
        "--file", info.file,
        "--line-start", tostring(s),
        "--line-end", tostring(e),
        "--side", info.side,
        "--rev", info.rev,
        "--line-text", line_text,
        "--type", typ,
        "--text", text,
      }, info.cwd, function(out)
        if out.code ~= 0 then
          vim.notify("nrev add failed: " .. (out.stderr or ""), vim.log.levels.ERROR)
          return
        end
        M.refresh(bufnr)
      end)
    end)
  end)
end

local function jump(dir)
  local rows = vim.b.nrev_comments or {}
  if #rows == 0 then
    return
  end
  local cur = vim.fn.line(".")
  local sorted = vim.deepcopy(rows)
  table.sort(sorted, function(a, b)
    return a.row < b.row
  end)
  local target
  if dir > 0 then
    for _, r in ipairs(sorted) do
      if r.row > cur then
        target = r
        break
      end
    end
    target = target or sorted[1]
  else
    for i = #sorted, 1, -1 do
      if sorted[i].row < cur then
        target = sorted[i]
        break
      end
    end
    target = target or sorted[#sorted]
  end
  vim.api.nvim_win_set_cursor(0, { target.row, 0 })
end

function M.next()
  jump(1)
end

function M.prev()
  jump(-1)
end

local function comment_at_cursor()
  local cur = vim.fn.line(".")
  for _, r in ipairs(vim.b.nrev_comments or {}) do
    if r.row <= cur and cur <= r.row_end then
      return r
    end
  end
  vim.notify("nrev: no comment under cursor", vim.log.levels.INFO)
end

function M.toggle_resolve()
  local r = comment_at_cursor()
  if not r then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local info = buf_info(bufnr)
  local cwd = info and info.cwd or vim.uv.cwd()
  local cmd = r.status == "resolved" and { "reopen", tostring(r.id) } or { "resolve", tostring(r.id) }
  M.run(cmd, cwd, function()
    M.refresh(bufnr)
  end)
end

function M.delete()
  local r = comment_at_cursor()
  if not r then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local info = buf_info(bufnr)
  local cwd = info and info.cwd or vim.uv.cwd()
  M.run({ "delete", tostring(r.id) }, cwd, function()
    M.refresh(bufnr)
  end)
end

function M.export()
  local info = buf_info(vim.api.nvim_get_current_buf())
  local cwd = info and info.cwd or vim.uv.cwd()
  M.run({ "list", "--md", "--status", "open" }, cwd, function(out)
    if out.code ~= 0 then
      return
    end
    vim.fn.setreg("+", out.stdout or "")
    vim.notify("nrev: open comments copied to clipboard")
  end)
end

function M.pick()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("nrev: fzf-lua not available", vim.log.levels.WARN)
    return
  end
  local info = buf_info(vim.api.nvim_get_current_buf())
  local cwd = info and info.cwd or vim.uv.cwd()
  M.run({ "list", "--json", "--status", "all" }, cwd, function(out)
    if out.code ~= 0 then
      return
    end
    local okj, comments = pcall(vim.json.decode, out.stdout)
    if not okj then
      return
    end
    local entries = {}
    for _, c in ipairs(comments) do
      table.insert(entries, ("%s:%d [%s/%s] %s"):format(c.file, c.line_start, c.type, c.status, c.text))
    end
    fzf.fzf_exec(entries, {
      prompt = "review> ",
      actions = {
        ["default"] = function(selected)
          local file, line = selected[1]:match("^(.-):(%d+)")
          if file then
            local out = vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }):wait()
            local top = out.code == 0 and vim.trim(out.stdout or "") or cwd
            vim.cmd("edit " .. vim.fn.fnameescape(top .. "/" .. file))
            vim.api.nvim_win_set_cursor(0, { tonumber(line), 0 })
          end
        end,
      },
    })
  end)
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  local group = vim.api.nvim_create_augroup("nrev", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "FocusGained" }, {
    group = group,
    callback = function(ev)
      M.refresh(ev.event == "FocusGained" and vim.api.nvim_get_current_buf() or ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "diffview://*",
    callback = function(ev)
      M.refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_user_command("NrevRefresh", function()
    M.refresh()
  end, {})
  vim.keymap.set({ "n", "v" }, "<leader>rc", M.add, { desc = "Review: add comment" })
  vim.keymap.set("n", "]a", M.next, { desc = "Next review comment" })
  vim.keymap.set("n", "[a", M.prev, { desc = "Prev review comment" })
  vim.keymap.set("n", "<leader>rl", M.pick, { desc = "Review: list comments" })
  vim.keymap.set("n", "<leader>rx", M.toggle_resolve, { desc = "Review: resolve/reopen" })
  vim.keymap.set("n", "<leader>rd", M.delete, { desc = "Review: delete comment" })
  vim.keymap.set("n", "<leader>re", M.export, { desc = "Review: export to clipboard" })
  require("nrev.diffview").setup()
  vim.schedule(function()
    M.refresh()
  end)
end

return M
