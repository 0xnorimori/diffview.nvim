local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local git = helpers.git
local wait_for = helpers.wait_for

describe("diffview inline layout", function()
  local clubmate, repo, tab, ui

  local function view()
    return require("diffview.lib").tabpage_to_view(tab)
  end

  local function select(path)
    clubmate.select(path, tab)
    wait_for(function()
      local cur = view().cur_entry
      return cur and cur.path == path and cur.opened
    end)
  end

  local function marks(win)
    local ns = vim.api.nvim_create_namespace("diffview_inline")
    return vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, { details = true })
  end

  local function texts(line)
    local text = table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, line))
    return (vim.trim(text):gsub("%s+", " "):gsub("^− ", "−"))
  end

  local function inline()
    clubmate.set_layout("inline", tab)
    wait_for(function()
      local l = view().cur_layout
      return #l.windows == 1 and #marks(l.windows[1].id) > 0
    end)
    return view().cur_layout.windows[1].id
  end

  local function diff(win)
    local removed, added = {}, {}
    for _, m in ipairs(marks(win)) do
      for _, line in ipairs(m[4].virt_lines or {}) do
        table.insert(removed, { m[2], texts(line) })
      end
      if m[4].line_hl_group then
        table.insert(added, m[2])
      end
    end
    return { removed = removed, added = added }
  end

  before_each(function()
    vim.cmd("runtime! plugin/diffview.lua")
    require("diffview").setup({ use_icons = false })
    require("nrev").setup({ bin = helpers.nrev_bin })
    clubmate = require("diffview.clubmate")
    ui = { select = vim.ui.select, input = vim.ui.input }
    repo = helpers.make_repo()
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      local cur = view().cur_entry
      return cur ~= nil and cur.path == "a.go" and cur.opened
    end)
  end)

  after_each(function()
    vim.ui.select, vim.ui.input = ui.select, ui.input
    clubmate.close(tab)
  end)

  it("re-renders when the buffer is edited", function()
    local win = inline()
    local buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "func A() {}" })
    wait_for(function()
      return vim.deep_equal({ removed = {}, added = { 2 } }, diff(win))
    end)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    wait_for(function()
      return vim.deep_equal({ removed = { { 0, "−1 package a" } }, added = { 1 } }, diff(win))
    end)
  end)

  helpers.nrev_it("shows old-side comments under their old line", function()
    local nrev = require("nrev")
    local layout = view().cur_layout
    local left = layout.a.id
    local old = vim.api.nvim_win_get_buf(left)
    local function comment(line, text)
      local before = #(vim.b[old].nrev_comments or {})
      vim.ui.select = function(_, _, cb)
        cb("issue")
      end
      vim.ui.input = function(_, cb)
        cb(text)
      end
      vim.api.nvim_set_current_win(left)
      vim.api.nvim_win_set_cursor(left, { line, 0 })
      nrev.add()
      wait_for(function()
        return #(vim.b[old].nrev_comments or {}) == before + 1
      end)
    end
    comment(2, "gone for good")
    comment(1, "keep the package")

    local win = inline()
    local function lines()
      local out = {}
      for _, m in ipairs(marks(win)) do
        for _, line in ipairs(m[4].virt_lines or {}) do
          table.insert(out, { m[2], m[4].virt_lines_above or false, texts(line) })
        end
      end
      return out
    end
    wait_for(function()
      return #lines() == 5
    end)
    local got = lines()
    eq({ 0, false, "▎ keep the package" }, got[2])
    eq({ 1, true, "−2 func A() {}" }, got[3])
    eq({ 1, true, "▎ gone for good" }, got[5])

    local id = vim.json.decode(helpers.nrev(repo, "list", "--json", "--status", "all"))[1].id
    helpers.nrev(repo, "resolve", tostring(id))
    vim.api.nvim_exec_autocmds("User", { pattern = "NrevCommentsChanged" })
    wait_for(function()
      return #lines() == 4 and vim.iter(lines()):any(function(l)
        return l[3]:find("resolved", 1, true) ~= nil
      end)
    end)
  end)

  it("keeps the removed lines above line 1 reachable", function()
    clubmate.close(tab)
    local top = {}
    for i = 1, 100 do
      top[i] = "line " .. i
    end
    vim.fn.writefile(top, repo .. "/top.txt")
    git(repo, "add", "top.txt")
    git(repo, "commit", "-q", "-m", "top")
    vim.fn.writefile(vim.list_slice(top, 3), repo .. "/top.txt")
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      local cur = view().cur_entry
      return cur ~= nil and cur.opened
    end)
    select("top.txt")
    local win = inline()
    local function topfill()
      return vim.api.nvim_win_call(win, vim.fn.winsaveview).topfill
    end
    local function scroll(keys)
      vim.api.nvim_win_call(win, function()
        vim.cmd("norm! " .. vim.keycode(keys))
      end)
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
    end
    eq(2, topfill())
    scroll("G")
    scroll("gg")
    eq(2, topfill())
    scroll("20<C-e>")
    scroll("20<C-y>")
    eq(2, topfill())
    scroll("<C-e>")
    eq(1, topfill())
  end)
end)
