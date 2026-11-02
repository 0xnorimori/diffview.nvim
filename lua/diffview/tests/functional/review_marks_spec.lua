local helpers = require("diffview.tests.helpers")

local eq = helpers.eq
local git = helpers.git
local nrev = helpers.nrev
local wait_for = helpers.wait_for

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

describe("diffview.review.marks", function()
  local clubmate, repo, tab, restored

  local function view()
    return require("diffview.lib").tabpage_to_view(tab)
  end

  local function file(path, kind)
    for _, f in view().files:iter() do
      if f.path == path and (not kind or f.kind == kind) then
        return f
      end
    end
  end

  local function open(base, nowait)
    restored = false
    tab = clubmate.open({ cwd = repo, base = base == nil and "HEAD" or base or nil })
    if not nowait then
      wait_for(function()
        return restored
      end)
    end
  end

  local function reopen(base)
    clubmate.close(tab)
    open(base)
  end

  local function stored(path)
    return nrev(repo, "reviewed", "list"):find(path .. "\t", 1, true) ~= nil
  end

  local function mark(path)
    clubmate.set_reviewed(path, true, tab)
    wait_for(function()
      return stored(path)
    end)
  end

  before_each(function()
    vim.cmd("runtime! plugin/diffview.lua")
    require("diffview").setup({ use_icons = false })
    require("nrev").setup({ bin = helpers.nrev_bin })
    vim.api.nvim_create_autocmd("User", {
      pattern = "NrevReviewedRestored",
      callback = function()
        restored = true
      end,
    })
    clubmate = require("diffview.clubmate")
    repo = helpers.make_repo()
    open()
  end)

  after_each(function()
    clubmate.close(tab)
  end)

  helpers.nrev_it("marks a file and restores it on reopen", function()
    mark("a.go")
    reopen()
    eq({ true, false }, { file("a.go").reviewed, file("a.go").stale })
  end)

  helpers.nrev_it("turns a reviewed file stale when it changes", function()
    mark("a.go")
    vim.fn.writefile({ "package a", "func C() {}" }, repo .. "/a.go")
    restored = false
    view():update_files()
    wait_for(function()
      return restored and file("a.go").stale
    end)
    eq(false, file("a.go").reviewed)
    clubmate.set_reviewed("a.go", true, tab)
    eq({ true, false }, { file("a.go").reviewed, file("a.go").stale })
  end)

  helpers.nrev_it("keeps a mark across left sides", function()
    git(repo, "add", "a_test.go")
    git(repo, "commit", "-q", "-m", "tests")
    reopen("HEAD~1")
    mark("a.go")
    reopen("HEAD")
    eq(true, file("a.go").reviewed)
  end)

  helpers.nrev_it("marks untracked and deleted files", function()
    git(repo, "rm", "-q", "--cached", "a_test.go")
    vim.fn.delete(repo .. "/a_test.go")
    git(repo, "add", "-A", "a_test.go")
    reopen()
    mark("new.txt")
    mark("a_test.go")
    reopen()
    eq({ true, true }, { file("new.txt").reviewed, file("a_test.go").reviewed })
  end)

  helpers.nrev_it("keeps marks when git cannot hash one path", function()
    mark("a.go")
    clubmate.close(tab)
    vim.fn.mkdir(repo .. "/sub", "p")
    git(repo .. "/sub", "init", "-q")
    vim.fn.writefile({ "x" }, repo .. "/sub/x")
    git(repo .. "/sub", "add", "x")
    git(repo .. "/sub", "commit", "-q", "-m", "i")
    open()
    eq({ true, false }, { file("a.go").reviewed, file("a.go").stale })
  end)

  helpers.nrev_it("keeps a toggle made before the refresh lands", function()
    clubmate.close(tab)
    local nrev_mod = require("nrev")
    local run = nrev_mod.run
    nrev_mod.run = function(args, cwd, cb)
      if args[1] == "reviewed" and args[2] == "list" and cb then
        return run(args, cwd, function(out)
          vim.defer_fn(function()
            cb(out)
          end, 300)
        end)
      end
      return run(args, cwd, cb)
    end
    open("HEAD", true)
    wait_for(function()
      return view() and file("a.go") ~= nil
    end)
    clubmate.set_reviewed("a.go", true, tab)
    wait_for(function()
      return restored
    end)
    nrev_mod.run = run
    eq(true, file("a.go").reviewed)
    wait_for(function()
      return stored("a.go")
    end)
  end)

  helpers.nrev_it("unmarking one entry keeps the other entry's mark of the same path", function()
    clubmate.close(tab)
    git(repo, "add", "a.go")
    vim.fn.writefile({ "package a", "func Z() {}" }, repo .. "/a.go")
    open(false)
    local working, staged = file("a.go", "working"), file("a.go", "staged")
    working.reviewed, staged.reviewed = true, true
    vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewReviewedToggled" })
    wait_for(function()
      local _, n = nrev(repo, "reviewed", "list"):gsub("a.go\t", "")
      return n == 2
    end)
    working.reviewed = false
    vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewReviewedToggled" })
    wait_for(function()
      local _, n = nrev(repo, "reviewed", "list"):gsub("a.go\t", "")
      return n == 1
    end)
    assert.truthy(nrev(repo, "reviewed", "list"):find("a.go\t" .. staged.content_id, 1, true))
  end)
end)
