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
    require("diffview").setup({ use_icons = false })
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
end)
