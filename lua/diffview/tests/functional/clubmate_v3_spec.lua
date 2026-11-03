local helpers = require("diffview.tests.helpers")

local eq = helpers.eq
local wait_for = helpers.wait_for

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

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

local function was_sent(sent, kind, tab)
  return vim.tbl_contains(sent, function(v)
    return vim.deep_equal(v, { 7, "clubmate", { event = "review", kind = kind, tab = tab } })
  end, { predicate = true })
end

describe("diffview.clubmate v3", function()
  local clubmate, repo, tab

  local function view()
    return require("diffview.lib").tabpage_to_view(tab)
  end

  local function opened(path)
    local cur = view().cur_entry
    return cur ~= nil and cur.path == path and cur.opened
  end

  local function panel_text()
    local lines = {}
    for _, buf in ipairs(view().panel:buffers()) do
      vim.list_extend(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end
    return table.concat(lines, "\n")
  end

  before_each(function()
    vim.cmd("runtime! plugin/diffview.lua")
    require("diffview").setup({ use_icons = false })
    clubmate = require("diffview.clubmate")
    repo = helpers.make_repo()
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      return opened("a.go")
    end)
  end)

  after_each(function()
    clubmate.close(tab)
  end)

  it("keeps the panel of a host-opened review visible", function()
    eq(3, clubmate.version)
    assert.is_truthy(view().panel:is_open())
  end)

  it("prints the subtitle and recipient the host sets", function()
    clubmate.set_meta(tab, { subtitle = "Claude · Show missed cron runs", recipient = "Claude" })
    assert.truthy(panel_text():find("Review Claude · Show missed cron runs", 1, true))
    clubmate.set_meta(tab, { subtitle = "feat ↔ main" })
    assert.truthy(panel_text():find("Review feat ↔ main", 1, true))
  end)

  it("sends a send event when gS is pressed in the panel", function()
    capture(function(sent)
      clubmate.subscribe(7)
      vim.api.nvim_set_current_win(view().panel.winid)
      vim.cmd("normal gS")
      assert.is_true(was_sent(sent, "send", tab))
    end)
  end)

  it("reports and sets filters with counts", function()
    eq({
      code = { shown = true, count = 2 },
      tests = { shown = false, count = 2 },
      generated = { shown = false, count = 0 },
      reviewed = { shown = true, count = 0 },
    }, clubmate.filters(tab))
    clubmate.set_reviewed("a.go", true, tab)
    clubmate.set_filter("tests", true, tab)
    eq({ shown = true, count = 1 }, clubmate.filters(tab).reviewed)
    clubmate.set_filter("code", false, tab)
    eq({ "a_test.go", "b_test.go" }, vim.tbl_map(function(f)
      return f.path
    end, view().panel:ordered_file_list()))
    local filters = clubmate.filters(tab)
    eq({ shown = false, count = 2 }, filters.code)
    eq({ shown = true, count = 2 }, filters.tests)
    eq({ shown = true, count = 0 }, filters.reviewed)
  end)

  it("rejects an unknown filter", function()
    local ok, err = clubmate.set_filter("docs", true, tab)
    eq(nil, ok)
    assert.truthy(err:find("unknown filter", 1, true))
  end)

  it("skips hidden code files on next unreviewed", function()
    clubmate.set_filter("tests", true, tab)
    clubmate.set_filter("code", false, tab)
    eq("a_test.go", clubmate.next_unreviewed(1, tab))
  end)

  it("moves past a reviewed current file while reviewed files are hidden", function()
    clubmate.set_reviewed("a.go", true, tab)
    clubmate.set_filter("reviewed", false, tab)
    eq("new.txt", clubmate.next_unreviewed(1, tab))
  end)

  it("opens the next file to review with ]f in a diff pane", function()
    vim.api.nvim_set_current_win(view().cur_layout.b.id)
    vim.cmd("normal ]f")
    wait_for(function()
      return opened("new.txt")
    end)
    vim.api.nvim_set_current_win(view().cur_layout.b.id)
    vim.cmd("normal [f")
    wait_for(function()
      return opened("a.go")
    end)
  end)
end)
