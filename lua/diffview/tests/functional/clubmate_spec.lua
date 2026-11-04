local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local nrev_bin = helpers.nrev_bin
local git = helpers.git
local nrev = helpers.nrev
local wait_for = helpers.wait_for
local make_repo = helpers.make_repo

local function capture(fn)
  local sent = {}
  local rpcnotify = vim.rpcnotify
  vim.rpcnotify = function(...)
    table.insert(sent, { ... })
  end
  local ok, err = pcall(fn, sent)
  vim.rpcnotify = rpcnotify
  if not ok then
    error(err, 0)
  end
end

local function was_sent(sent, kind, path, tab)
  local expected = { 7, "clubmate", { event = "review", kind = kind, path = path, tab = tab } }
  return vim.tbl_contains(sent, function(v)
    return vim.deep_equal(v, expected)
  end, { predicate = true })
end

describe("diffview.clubmate", function()
  local clubmate, repo, tab

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
    require("diffview").setup({
      use_icons = false,
      file_panel = { filters = { tests = { hidden = false }, generated = { hidden = false } } },
    })
    clubmate = require("diffview.clubmate")
    repo = make_repo()
    open_review()
  end)

  after_each(function()
    clubmate.close(tab)
  end)

  it("lists modified and untracked entries with stats, category and kind against a base", function()
    eq({
      {
        path = "a.go",
        status = "M",
        additions = 2,
        deletions = 1,
        reviewed = false,
        stale = false,
        comments = 0,
        category = "code",
        kind = "modified",
      },
      {
        path = "a_test.go",
        status = "M",
        additions = 1,
        deletions = 0,
        reviewed = false,
        stale = false,
        comments = 0,
        category = "test",
        kind = "modified",
      },
      {
        path = "b_test.go",
        status = "?",
        additions = 1,
        deletions = 0,
        reviewed = false,
        stale = false,
        comments = 0,
        category = "test",
        kind = "new",
      },
      {
        path = "new.txt",
        status = "?",
        additions = 3,
        deletions = 0,
        reviewed = false,
        stale = false,
        comments = 0,
        category = "code",
        kind = "new",
      },
    }, clubmate.entries(tab))
  end)

  it("opens a branch tip read-only", function()
    clubmate.close(tab)
    git(repo, "add", "a.go")
    local tree = git(repo, "write-tree")
    local base = git(repo, "rev-parse", "HEAD")
    git(repo, "branch", "feat", git(repo, "commit-tree", tree, "-p", "HEAD", "-m", "feat"))
    git(repo, "reset", "-q")

    tab = clubmate.open({ cwd = repo, base = "HEAD", head = "feat" })
    wait_for(function()
      return opened(view(), "a.go")
    end)

    eq({ "a.go" }, vim.tbl_map(function(e)
      return e.path
    end, clubmate.entries(tab)))
    local info = clubmate.info(tab)
    eq(false, info.editable)
    eq("HEAD", info.base)
    eq("feat", info.head)
    eq(base, info.merge_base)
    eq({ left = "HEAD", right = "feat" }, info.labels)
  end)

  it("reports the working tree as editable with label overrides", function()
    clubmate.close(tab)
    tab = clubmate.open({ cwd = repo, base = "HEAD", labels = { left = "Before turn 3" } })
    wait_for(function()
      return opened(view(), "a.go")
    end)
    local info = clubmate.info(tab)
    eq(true, info.editable)
    eq(nil, info.head)
    eq({ left = "Before turn 3", right = "Working tree" }, info.labels)
  end)

  it("reports renames and deletions with their kind", function()
    clubmate.close(tab)
    vim.fn.writefile({ "1", "2", "3", "4", "5", "6", "7", "8" }, repo .. "/lines.txt")
    git(repo, "add", "lines.txt")
    git(repo, "commit", "-q", "-m", "lines")
    git(repo, "mv", "lines.txt", "moved.txt")
    git(repo, "rm", "-q", "--cached", "a.go")
    vim.fn.delete(repo .. "/a.go")
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      return entry("moved.txt") ~= nil and view().cur_entry ~= nil and view().cur_entry.opened
    end)
    eq("renamed", entry("moved.txt").kind)
    eq("lines.txt", entry("moved.txt").old_path)
    eq("deleted", entry("a.go").kind)
  end)

  it("keeps plain DiffviewOpen against a rev free of untracked files", function()
    local lib = require("diffview.lib")
    require("diffview").open({ "-C" .. repo, "HEAD" })
    local plain = lib.get_current_view()
    wait_for(function()
      return opened(plain, "a.go")
    end)

    local statuses = {}
    for _, file in plain.files:iter() do
      statuses[file.path] = file.status
    end
    eq({ ["a.go"] = "M", ["a_test.go"] = "M" }, statuses)

    plain:close()
    lib.dispose_view(plain)
  end)

  it("toggles the file panel", function()
    clubmate.set_panel(false, tab)
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
    eq({ "a.go", "new.txt" }, vim.tbl_map(function(e)
      return e.path
    end, clubmate.entries(tab)))

    clubmate.set_excludes({}, tab)
    wait_for(function()
      return entry("a_test.go") ~= nil
    end)
    eq(true, entry("a_test.go").reviewed)
  end)

  it("never flips back a mark changed underneath on refresh", function()
    clubmate.toggle_reviewed("a.go", tab)
    for _, file in view().files:iter() do
      if file.path == "new.txt" then
        file.reviewed = true
      end
    end

    local updated = false
    view().emitter:on("files_updated", function()
      updated = true
    end)
    view():update_files()
    wait_for(function()
      return updated
    end)

    eq(true, entry("a.go").reviewed)
    eq(true, entry("new.txt").reviewed)
  end)

  it("jumps to the next unreviewed file with wrap-around and opens it", function()
    clubmate.toggle_reviewed("a.go", tab)

    eq("a_test.go", clubmate.next_unreviewed(1, tab))
    wait_for(function()
      return opened(view(), "a_test.go")
    end)

    eq("new.txt", clubmate.next_unreviewed(-1, tab))
    wait_for(function()
      return opened(view(), "new.txt")
    end)
  end)

  it("defers selects issued before the first file is open", function()
    clubmate.close(tab)
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        table.insert(errors, msg)
      end
    end
    vim.v.errmsg = ""
    local ok, err = pcall(function()
      tab = clubmate.open({ cwd = repo, base = "HEAD" })
      clubmate.select("b_test.go", tab)
      view().emitter:once("files_updated", function()
        clubmate.select("new.txt", tab)
      end)
      wait_for(function()
        return opened(view(), "new.txt")
      end)
      vim.wait(300)
    end)
    vim.notify = notify
    assert(ok, err)
    eq({}, errors)
    eq("", vim.v.errmsg)
  end)

  it("returns an error instead of echoing it", function()
    local echoed = {}
    local notify = vim.notify
    vim.notify = function(msg)
      table.insert(echoed, msg)
    end
    local plain_dir = vim.fn.tempname()
    vim.fn.mkdir(plain_dir, "p")
    local ok, missing, err = pcall(clubmate.open, { cwd = plain_dir })
    vim.notify = notify
    assert(ok, missing)
    eq(nil, missing)
    assert.is_truthy(err:find("Not a repo", 1, true))
    eq({}, echoed)
  end)

  it("notifies subscribers when a file's reviewed mark is toggled", function()
    capture(function(sent)
      clubmate.subscribe(7)
      clubmate.toggle_reviewed("new.txt", tab)
      assert.is_true(was_sent(sent, "reviewed", "new.txt", tab))
    end)
  end)

  it("never runs shell commands from the cwd or exclude globs", function()
    clubmate.close(tab)
    local marker = vim.fn.tempname()
    local evil = vim.fn.tempname() .. "/r `touch " .. marker .. "` $HOME"
    vim.fn.mkdir(evil, "p")
    git(evil, "init", "-q")
    vim.fn.writefile({ "a" }, evil .. "/a.go")
    vim.fn.writefile({ "x" }, evil .. "/$HOME.go")
    vim.fn.writefile({ "y" }, evil .. "/`touch " .. vim.fs.basename(marker) .. "`.go")
    git(evil, "add", ".")
    git(evil, "commit", "-q", "-m", "init")
    vim.fn.writefile({ "b" }, evil .. "/a.go")
    vim.fn.writefile({ "x2" }, evil .. "/$HOME.go")
    vim.fn.writefile({ "y2" }, evil .. "/`touch " .. vim.fs.basename(marker) .. "`.go")

    tab = clubmate.open({
      cwd = evil,
      base = "HEAD",
      excludes = { "$HOME.go", "`touch " .. marker .. "`*" },
    })
    wait_for(function()
      local cur = view().cur_entry
      return #clubmate.entries(tab) == 2 and cur ~= nil and cur.opened
    end)

    eq({ "`touch " .. vim.fs.basename(marker) .. "`.go", "a.go" }, vim.tbl_map(function(e)
      return e.path
    end, clubmate.entries(tab)))
    eq(nil, vim.uv.fs_stat(marker))
  end)

  it("counts an untracked symlink as one line without following it", function()
    local fifo = repo .. "/pipe"
    assert(vim.fn.system({ "mkfifo", fifo }) == "" and vim.v.shell_error == 0)
    assert(vim.uv.fs_symlink(fifo, repo .. "/link"))
    view():update_files()
    wait_for(function()
      return entry("link") ~= nil
    end)
    eq(1, entry("link").additions)
  end)

  it("sets a reviewed mark idempotently", function()
    eq(true, clubmate.set_reviewed("a.go", true, tab))
    eq(true, clubmate.set_reviewed("a.go", true, tab))
    eq(false, clubmate.set_reviewed("a.go", false, tab))
    eq(false, entry("a.go").reviewed)
  end)

  it("notifies subscribers when the user closes the review, not when the module does", function()
    capture(function(sent)
      clubmate.subscribe(7)
      clubmate.close(tab)
      assert.is_false(was_sent(sent, "closed", nil, tab))

      open_review()
      vim.cmd("DiffviewClose")
      assert.is_true(was_sent(sent, "closed", nil, tab))
    end)
  end)

  it("notifies subscribers when the user closes a review other than the newest", function()
    capture(function(sent)
      clubmate.subscribe(7)
      local older = tab
      open_review()
      local newer = tab
      assert.are_not.equal(older, newer)

      vim.api.nvim_set_current_tabpage(older)
      vim.cmd("DiffviewClose")
      assert.is_true(was_sent(sent, "closed", nil, older))
      assert.is_false(was_sent(sent, "closed", nil, newer))

      vim.api.nvim_set_current_tabpage(newer)
      vim.cmd("DiffviewClose")
      assert.is_true(was_sent(sent, "closed", nil, newer))
    end)
  end)

  it("keeps async messages of module-driven opens out of vim.notify", function()
    local echoed = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(echoed, { msg, level })
    end
    local ok, err = pcall(function()
      local async = require("diffview.async")
      local v = view()
      local set_file = v.set_file
      v.set_file = async.void(function(self, ...)
        async.await(async.timeout(50))
        async.await(async.schedule_now())
        vim.notify("async boom", vim.log.levels.ERROR)
        async.await(set_file(self, ...))
      end)
      clubmate.select("new.txt", tab)
      wait_for(function()
        return opened(view(), "new.txt")
      end)
      vim.wait(200)
    end)
    vim.notify = notify
    assert(ok, err)
    eq({}, echoed)
  end)

  local nrev_it = helpers.nrev_it

  nrev_it("reflects nrev reviewed marks and open comment counts, also of comments added outside nvim", function()
    clubmate.close(tab)
    require("nrev").setup({ bin = nrev_bin })
    local function comment(text)
      nrev(
        repo,
        "add",
        "--file", "a.go",
        "--line-start", "1",
        "--line-end", "1",
        "--side", "new",
        "--rev", "WORKING",
        "--line-text", "package a",
        "--type", "note",
        "--text", text
      )
    end
    nrev(repo, "reviewed", "set", "a.go", "--content-id", git(repo, "hash-object", "a.go"))
    comment("first")

    capture(function(sent)
      clubmate.subscribe(7)
      open_review()
      wait_for(function()
        return was_sent(sent, "reviewed_restored", nil, tab)
      end)
      eq(true, entry("a.go").reviewed)
      eq(1, entry("a.go").comments)

      for i = #sent, 1, -1 do
        sent[i] = nil
      end
      comment("second")
      wait_for(function()
        return was_sent(sent, "comments", nil, tab)
      end)
      eq(2, entry("a.go").comments)
      wait_for(function()
        local ns = vim.api.nvim_get_namespaces().nrev
        local buf = view().cur_layout.b.file.bufnr
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
          for _, line in ipairs(m[4].virt_lines or {}) do
            for _, chunk in ipairs(line) do
              if chunk[1]:find("second", 1, true) then
                return true
              end
            end
          end
        end
      end)
    end)
  end)

  nrev_it("restores persisted marks of files shown again after an exclude is lifted", function()
    clubmate.close(tab)
    require("nrev").setup({ bin = nrev_bin })
    nrev(repo, "reviewed", "set", "a_test.go", "--content-id", git(repo, "hash-object", "a_test.go"))

    capture(function(sent)
      clubmate.subscribe(7)
      tab = clubmate.open({ cwd = repo, base = "HEAD", excludes = { "*_test.go" } })
      wait_for(function()
        return was_sent(sent, "reviewed_restored", nil, tab)
      end)
      eq(nil, entry("a_test.go"))

      clubmate.set_excludes({}, tab)
      wait_for(function()
        local e = entry("a_test.go")
        return e ~= nil and e.reviewed
      end)
    end)
  end)

  nrev_it("comments lists nrev rows", function()
    clubmate.close(tab)
    require("nrev").setup({ bin = nrev_bin })
    nrev(
      repo,
      "add",
      "--file", "a.go",
      "--line-start", "2",
      "--line-end", "3",
      "--side", "new",
      "--rev", "WORKING",
      "--line-text", "func A() int { return 1 }",
      "--type", "issue",
      "--text", "why one"
    )
    open_review()
    local rows = clubmate.comments(tab)
    eq(1, #rows)
    local c = rows[1]
    eq({ "a.go", "new", 2, 3, "issue", "why one", "open", "func A() int { return 1 }", "WORKING" },
      { c.file, c.side, c.line_start, c.line_end, c.type, c.text, c.status, c.line_text, c.rev })
    assert.is_number(c.id)
  end)

  nrev_it("marks a file changed outside nvim after it was reviewed as stale", function()
    clubmate.close(tab)
    require("nrev").setup({ bin = nrev_bin })
    capture(function(sent)
      clubmate.subscribe(7)
      open_review()
      wait_for(function()
        return was_sent(sent, "reviewed_restored", nil, tab)
      end)
      clubmate.set_reviewed("a.go", true, tab)
      wait_for(function()
        return nrev(repo, "reviewed", "list"):find("a.go", 1, true) ~= nil
      end)
      vim.fn.writefile({ "package a", "func A() int { return 2 }" }, repo .. "/a.go")
      wait_for(function()
        local e = entry("a.go")
        return e.stale and not e.reviewed
      end)
    end)
  end)
end)
