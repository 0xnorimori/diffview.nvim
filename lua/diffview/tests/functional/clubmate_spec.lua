local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local function git(dir, ...)
  local cmd = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
  vim.fn.system(vim.list_extend(cmd, { ... }))
end

local function wait_for(pred)
  assert(vim.wait(5000, pred, 20), "condition not met in time")
end

local function make_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  git(repo, "init", "-q")
  vim.fn.writefile({ "package a", "func A() {}" }, repo .. "/a.go")
  vim.fn.writefile({ "package a" }, repo .. "/a_test.go")
  git(repo, "add", ".")
  git(repo, "commit", "-q", "-m", "init")
  vim.fn.writefile({ "package a", "func A() int { return 1 }", "func B() {}" }, repo .. "/a.go")
  vim.fn.writefile({ "package a", "func TestA() {}" }, repo .. "/a_test.go")
  vim.fn.writefile({ "one", "two", "three" }, repo .. "/new.txt")
  return repo
end

describe("diffview.clubmate", function()
  local repo = make_repo()
  local clubmate, tab

  local function entry(path)
    for _, e in ipairs(clubmate.entries(tab)) do
      if e.path == path then
        return e
      end
    end
  end

  local function view()
    return require("diffview.lib").tabpage_to_view(tab)
  end

  local function opened(path)
    local cur = view().cur_entry
    return cur ~= nil and cur.path == path and cur.opened
  end

  before_each(function()
    vim.cmd("runtime! plugin/diffview.lua")
    require("diffview").setup({ use_icons = false })
    clubmate = require("diffview.clubmate")
    tab = clubmate.open({ cwd = repo })
    wait_for(function()
      return opened("a.go")
    end)
  end)

  after_each(function()
    clubmate.close(tab)
  end)

  it("lists modified and untracked entries with stats", function()
    eq(1, clubmate.version)
    eq({
      {
        path = "a.go",
        status = "M",
        additions = 2,
        deletions = 1,
        reviewed = false,
        comments = 0,
      },
      {
        path = "a_test.go",
        status = "M",
        additions = 1,
        deletions = 0,
        reviewed = false,
        comments = 0,
      },
      {
        path = "new.txt",
        status = "?",
        additions = 3,
        deletions = 0,
        reviewed = false,
        comments = 0,
      },
    }, clubmate.entries(tab))
  end)

  it("hides the file panel on open and toggles it", function()
    assert.is_falsy(view().panel:is_open())
    clubmate.set_panel(true, tab)
    assert.is_truthy(view().panel:is_open())
  end)

  it("keeps reviewed marks while excluded files are hidden and shown again", function()
    eq(true, clubmate.toggle_reviewed("a_test.go", tab))
    eq(true, entry("a_test.go").reviewed)

    clubmate.set_excludes({ "*_test.go" }, tab)
    wait_for(function()
      return entry("a_test.go") == nil
    end)
    eq(2, #clubmate.entries(tab))

    clubmate.set_excludes({}, tab)
    wait_for(function()
      return entry("a_test.go") ~= nil
    end)
    eq(true, entry("a_test.go").reviewed)
  end)

  it("jumps to the next unreviewed file with wrap-around and opens it", function()
    clubmate.toggle_reviewed("a.go", tab)

    eq("a_test.go", clubmate.next_unreviewed(1, tab))
    wait_for(function()
      return opened("a_test.go")
    end)

    eq("new.txt", clubmate.next_unreviewed(-1, tab))
    wait_for(function()
      return opened("new.txt")
    end)
  end)

  it("notifies subscribers when a file's reviewed mark is toggled", function()
    local sent = {}
    local rpcnotify = vim.rpcnotify
    vim.rpcnotify = function(...)
      table.insert(sent, { ... })
    end

    clubmate.subscribe(7)
    clubmate.toggle_reviewed("new.txt", tab)
    vim.rpcnotify = rpcnotify

    local expected = { 7, "clubmate", { event = "review", kind = "reviewed", path = "new.txt" } }
    assert.is_true(vim.tbl_contains(sent, function(v)
      return vim.deep_equal(v, expected)
    end, { predicate = true }))
  end)
end)
