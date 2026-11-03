local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local git = helpers.git
local wait_for = helpers.wait_for

describe("diffview.clubmate review profile", function()
  local clubmate, repo, tab

  local function view()
    return require("diffview.lib").tabpage_to_view(tab)
  end

  local function opened(v, path)
    local cur = v.cur_entry
    return cur ~= nil and cur.path == path and cur.opened
  end

  local function open_review()
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      return opened(view(), "a.go")
    end)
  end

  before_each(function()
    vim.cmd("runtime! plugin/diffview.lua")
    require("diffview").setup({ use_icons = false, enhanced_diff_hl = true })
    clubmate = require("diffview.clubmate")
    repo = helpers.make_repo()
    open_review()
  end)

  after_each(function()
    clubmate.close(tab)
  end)

  local function diff_wins()
    return vim.tbl_filter(function(w)
      return vim.wo[w].diff
    end, vim.api.nvim_tabpage_list_wins(tab))
  end

  local function bar_text(win)
    return (vim.wo[win].winbar:gsub("%%#[^#]*#", ""))
  end

  it("review tab hides tabline and relative numbers", function()
    clubmate.close(tab)
    vim.o.showtabline = 2
    vim.o.relativenumber = true
    open_review()
    eq(0, vim.o.showtabline)
    eq(2, #diff_wins())
    for _, w in ipairs(diff_wins()) do
      eq({ true, false }, { vim.wo[w].number, vim.wo[w].relativenumber })
    end

    vim.cmd("tabnew")
    eq(2, vim.o.showtabline)
    vim.cmd("tabclose")
    eq(0, vim.o.showtabline)

    clubmate.close(tab)
    vim.wait(50)
    eq(2, vim.o.showtabline)
    vim.o.relativenumber = false
  end)

  it("winbar leads with label and tag", function()
    clubmate.close(tab)
    local cp = git(repo, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "clubmate checkpoint 0b1c turn 3")
    tab = clubmate.open({ cwd = repo, base = cp })
    wait_for(function()
      return opened(view(), "a.go")
    end)
    local layout = view().cur_layout
    local left, right = bar_text(layout.a.id), bar_text(layout.b.id)
    eq("Before turn 3 checkpoint " .. cp:sub(1, 7) .. " %<a.go", vim.trim(left))
    eq("Working tree editable %<a.go", vim.trim(right))
    eq("Before turn 3", clubmate.info(tab).labels.left)
  end)

  it("tags a branch tip read-only and its base as the merge-base", function()
    clubmate.close(tab)
    local base = git(repo, "rev-parse", "HEAD")
    git(repo, "add", "a.go")
    git(repo, "branch", "feat", git(repo, "commit-tree", git(repo, "write-tree"), "-p", "HEAD", "-m", "feat"))
    git(repo, "reset", "-q")
    tab = clubmate.open({ cwd = repo, base = "HEAD", head = "feat", labels = { left = "main" } })
    wait_for(function()
      return opened(view(), "a.go")
    end)
    local layout = view().cur_layout
    eq("main merge-base " .. base:sub(1, 7) .. " %<a.go", vim.trim(bar_text(layout.a.id)))
    eq("feat read-only %<a.go", vim.trim(bar_text(layout.b.id)))
  end)

  local function select(path)
    clubmate.select(path, tab)
    wait_for(function()
      local cur = view().cur_entry
      return cur and cur.path == path and cur.opened
    end)
  end

  local function diff_hl(win)
    local out = {}
    vim.api.nvim_win_call(win, function()
      for i = 1, vim.api.nvim_buf_line_count(0) do
        out[i] = vim.fn.synIDattr(vim.fn.diff_hlID(i, 1), "name")
      end
    end)
    return out
  end

  local function message(win)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), -1, 0, -1, { details = true })) do
      if m[4].virt_text then
        return vim.trim(m[4].virt_text[1][1])
      end
    end
  end

  it("new file shows filler on the left", function()
    clubmate.close(tab)
    tab = clubmate.open({ cwd = repo, base = "HEAD", labels = { left = "Before turn 3" } })
    wait_for(function()
      return opened(view(), "a.go")
    end)
    select("new.txt")
    local layout = view().cur_layout
    local left, right = layout.a.id, layout.b.id
    eq("New file — nothing before turn 3", message(left))
    assert.is_truthy(vim.wo[left].fillchars:find("diff:╱", 1, true))
    eq(vim.fn.getwininfo(right)[1].textoff, vim.fn.getwininfo(left)[1].textoff)
    assert.is_truthy(vim.wo[left].winhl:find("DiffDelete:DiffviewDiffDeleteDim", 1, true))
    eq({ "DiffAdd", "DiffAdd", "DiffAdd" }, diff_hl(right))
    eq("Before turn 3 did not exist %<new.txt", vim.trim(bar_text(left)))
    eq("Working tree new file · 3 lines %<new.txt", vim.trim(bar_text(right)))
  end)

  it("deleted file mirrors it", function()
    clubmate.close(tab)
    vim.fn.delete(repo .. "/a.go")
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      return opened(view(), "a.go")
    end)
    local layout = view().cur_layout
    local left, right = layout.a.id, layout.b.id
    eq("Deleted in the working tree", message(right))
    eq({ "DiffAdd", "DiffAdd" }, diff_hl(left))
    eq("Working tree deleted %<a.go", vim.trim(bar_text(right)))
  end)

  it("keeps the winbar of a plain diffview on the filler side", function()
    clubmate.close(tab)
    require("diffview").setup({ use_icons = false, view = { default = { winbar_info = true } } })
    git(repo, "add", "new.txt")
    require("diffview").open({ "-C" .. repo, "HEAD" })
    local lib = require("diffview.lib")
    local plain = lib.get_current_view()
    wait_for(function()
      return plain.cur_entry ~= nil and plain.cur_entry.opened
    end)
    plain:set_file_by_path("new.txt")
    wait_for(function()
      return plain.cur_entry.path == "new.txt" and plain.cur_entry.opened
    end)
    local left = plain.cur_layout.a.id
    assert.is_truthy(message(left) ~= nil)
    assert.is_truthy(vim.wo[left].winbar ~= "")
    plain:close()
    lib.dispose_view(plain)
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
  end)

  it("keeps the filler message out of other review tabs", function()
    local first = tab
    select("new.txt")
    local first_left = view().cur_layout.a.id
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      local cur = view().cur_entry
      return cur ~= nil and cur.opened
    end)
    select("a.go")
    eq(nil, message(view().cur_layout.a.id))
    eq("New file — nothing before HEAD", message(first_left))
    clubmate.close(first)
  end)

  local function inline_marks(win)
    local ns = vim.api.nvim_create_namespace("diffview_inline")
    return vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, { details = true })
  end

  it("set_layout inline shows one pane with removed above added", function()
    clubmate.set_layout("inline", tab)
    wait_for(function()
      local l = view().cur_layout
      return #l.windows == 1 and #inline_marks(l.windows[1].id) > 0
    end)
    local win = view().cur_layout.windows[1].id
    local removed, added = {}, {}
    for _, m in ipairs(inline_marks(win)) do
      local d = m[4]
      for _, line in ipairs(d.virt_lines or {}) do
        local chunk = line[#line]
        table.insert(removed, { m[2], d.virt_lines_above, vim.trim(chunk[1]), chunk[2] })
      end
      if d.line_hl_group then
        table.insert(added, { m[2], d.line_hl_group })
      end
    end
    eq({ { 1, true, "func A() {}", "DiffDelete" } }, removed)
    eq({ { 1, "DiffAdd" }, { 2, "DiffAdd" } }, added)
    eq(false, vim.wo[win].diff)
    eq("%<a.go inline HEAD → Working tree", vim.trim(bar_text(win)))

    clubmate.set_layout("split", tab)
    wait_for(function()
      return #view().cur_layout.windows == 2
    end)
    eq({}, inline_marks(view().cur_layout.b.id))
  end)

  it("keeps inline for files that open later and for deleted files", function()
    clubmate.close(tab)
    vim.fn.delete(repo .. "/a_test.go")
    open_review()
    clubmate.set_layout("inline", tab)
    select("a_test.go")
    local win = view().cur_layout.windows[1].id
    wait_for(function()
      return #view().cur_layout.windows == 1 and #inline_marks(win) > 0
    end)
    local lines = {}
    for _, m in ipairs(inline_marks(win)) do
      for _, line in ipairs(m[4].virt_lines or {}) do
        table.insert(lines, vim.trim(line[#line][1]))
      end
    end
    eq({ "package a" }, lines)
  end)
end)

