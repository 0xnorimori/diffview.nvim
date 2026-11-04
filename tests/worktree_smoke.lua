local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)
vim.cmd("runtime! plugin/diffview.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function sh(args)
  vim.fn.system(args)
end
sh({ "git", "-C", tmp, "init", "-q" })
sh({ "git", "-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-q", "-m", "init" })
vim.fn.mkdir(tmp .. "/src", "p")
vim.fn.writefile({ "line1" }, tmp .. "/src/f.txt")
sh({ "git", "-C", tmp, "add", "." })
sh({ "git", "-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "add f" })

local tmp2 = vim.fn.tempname()
sh({ "git", "-C", tmp, "worktree", "add", "-q", "-b", "wt", tmp2 })

require("nrev").setup({ bin = root .. "/bin/nrev" })
vim.cmd("cd " .. tmp2)
vim.fn.writefile({ "line1 changed" }, tmp2 .. "/src/f.txt")
vim.cmd("DiffviewOpen")

local lib = require("diffview.lib")
local populated = vim.wait(5000, function()
  local v = lib.get_current_view()
  if not v or not v.files then
    return false
  end
  for _ in v.files:iter() do
    return true
  end
  return false
end, 50)
assert(populated, "diffview files never populated")

local old_buf
local ready = vim.wait(8000, function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:match("^diffview://.*/%.git/worktrees/") and #vim.fn.win_findbuf(b) > 0 then
      old_buf = b
      return true
    end
  end
  return false
end, 100)
assert(ready, "no windowed diffview worktree old-side buffer found")
local win = vim.fn.win_findbuf(old_buf)[1]
assert(win, "old-side buffer has no window")

vim.ui.input = function(_, cb)
  cb("worktree old side comment")
end
vim.api.nvim_set_current_win(win)
require("nrev").add()

local old_written = vim.wait(5000, function()
  local out = vim.system({ root .. "/bin/nrev", "list", "--json", "--status", "all" }, { cwd = tmp2, text = true }):wait()
  local s = out.stdout or ""
  return s:find("worktree old side comment", 1, true) ~= nil and s:find('"side":"old"', 1, true) ~= nil
end, 100)
assert(old_written, "old-side comment not written with side=old from worktree")

local old_rendered = vim.wait(5000, function()
  return #vim.api.nvim_buf_get_extmarks(old_buf, vim.api.nvim_create_namespace("nrev"), 0, -1, {}) == 1
end, 50)
assert(old_rendered, "old-side extmark not rendered in worktree")

print("OK")
