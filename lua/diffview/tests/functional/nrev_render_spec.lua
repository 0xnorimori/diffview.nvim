local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local nrev = helpers.nrev
local wait_for = helpers.wait_for

local LONG = ("Workspace is set only by the Always allow path. Say so in a comment, or the next reader "
  .. "will set it for Allow once too, and then the permission card shows the wrong scope to the user.")

describe("nrev comments in a review", function()
  local clubmate, repo, tab, id

  local function layout()
    return require("diffview.lib").tabpage_to_view(tab).cur_layout
  end

  local function marks(win, name)
    local ns = vim.api.nvim_create_namespace(name)
    return vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, { details = true })
  end

  local function virt_lines(win, name)
    local out = {}
    for _, m in ipairs(marks(win, name)) do
      vim.list_extend(out, m[4].virt_lines or {})
    end
    return out
  end

  local function width(line)
    local n = 0
    for _, chunk in ipairs(line) do
      n = n + vim.fn.strdisplaywidth(chunk[1])
    end
    return n
  end

  local function text_width(win)
    return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
  end

  local function height(win)
    return vim.api.nvim_win_text_height(win, {}).all
  end

  before_each(function()
    vim.o.columns = 170
    vim.cmd("runtime! plugin/diffview.lua")
    require("diffview").setup({ use_icons = false })
    require("nrev").setup({ bin = helpers.nrev_bin })
    clubmate = require("diffview.clubmate")
    repo = helpers.make_repo()
    id = vim.json.decode(nrev(
      repo,
      "add",
      "--file", "a.go",
      "--line-start", "2",
      "--line-end", "2",
      "--side", "new",
      "--rev", "WORKING",
      "--line-text", "func A() int { return 1 }",
      "--type", "issue",
      "--text", LONG
    )).id
    tab = clubmate.open({ cwd = repo, base = "HEAD" })
    wait_for(function()
      local cur = layout() and require("diffview.lib").tabpage_to_view(tab).cur_entry
      return cur and cur.path == "a.go" and cur.opened and #virt_lines(layout().b.id, "nrev") > 0
    end)
  end)

  after_each(function()
    clubmate.close(tab)
  end)

  helpers.nrev_it("comment wraps at pane width", function()
    local win = layout().b.id
    local lines = virt_lines(win, "nrev")
    assert.is_true(#lines >= 3)
    for _, line in ipairs(lines) do
      assert.is_true(width(line) <= text_width(win), vim.inspect(line))
    end
  end)

  helpers.nrev_it("other side gets equal filler", function()
    local l = layout()
    wait_for(function()
      return #virt_lines(l.a.id, "nrev_filler") == #virt_lines(l.b.id, "nrev")
    end)
    eq(height(l.a.id), height(l.b.id))
    for _, line in ipairs(virt_lines(l.a.id, "nrev_filler")) do
      assert.is_truthy(line[1][1]:find("╱", 1, true))
    end
  end)

  helpers.nrev_it("resolved collapses to one line", function()
    nrev(repo, "resolve", tostring(id))
    local l = layout()
    require("nrev").refresh(vim.api.nvim_win_get_buf(l.b.id))
    wait_for(function()
      return #virt_lines(l.b.id, "nrev") == 1 and #virt_lines(l.a.id, "nrev_filler") == 1
    end)
    eq(height(l.a.id), height(l.b.id))
  end)

  helpers.nrev_it("comments still render in the inline layout", function()
    clubmate.set_layout("inline", tab)
    local view = require("diffview.lib").tabpage_to_view(tab)
    wait_for(function()
      local l = view.cur_layout
      return #l.windows == 1 and l.rendered_buf ~= nil
    end)
    local win = view.cur_layout.windows[1].id
    wait_for(function()
      local lines = virt_lines(win, "nrev")
      return #lines >= 2 and vim.iter(lines):all(function(line)
        return width(line) <= text_width(win)
      end) and width(lines[2]) > 100
    end)
  end)
end)

describe("nrev on FocusGained", function()
  it("asks nrev only about file buffers", function()
    require("nrev").setup({ bin = helpers.nrev_bin })
    local file = vim.fn.tempname()
    vim.fn.writefile({ "x" }, file)
    vim.cmd("tabnew " .. vim.fn.fnameescape(file))
    file = vim.api.nvim_buf_get_name(0)
    for _, name in ipairs({ "neo-tree filesystem [1]", "[Pager]" }) do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, name)
      vim.cmd("split")
      vim.api.nvim_win_set_buf(0, buf)
    end
    local nrev_mod = require("nrev")
    local run = nrev_mod.run
    local asked = {}
    nrev_mod.run = function(args)
      table.insert(asked, args[#args])
    end
    vim.api.nvim_exec_autocmds("FocusGained", {})
    nrev_mod.run = run
    vim.cmd("tabclose")
    eq({ file }, asked)
  end)
end)

describe("nrev.diffview.map_line", function()
  it("maps a row to the same diff row on the other side", function()
    local a = "1\n2\n3\n4\n5\n6\n"
    local b = "1\nnew\n2\n3\n5\nx\ny\n6\n"
    local hunks = vim.diff(a, b, { result_type = "indices" })
    local map = require("nrev.diffview").map_line
    eq({ 1, 3, 4, 4, 5, 8 }, vim.tbl_map(function(row)
      return map(hunks, row)
    end, { 1, 2, 3, 4, 5, 6 }))
  end)
end)
