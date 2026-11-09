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
vim.fn.writefile({ "line1 changed" }, tmp .. "/src/f.txt")

require("nrev").setup({ bin = root .. "/bin/nrev" })
vim.cmd("cd " .. tmp)
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

local view = lib.get_current_view()
for _, file in view.files:iter() do
  file.reviewed = true
end
vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewReviewedToggled" })

local sha = vim.trim(vim.fn.system({ "git", "-C", tmp, "hash-object", "src/f.txt" }))
local written = vim.wait(5000, function()
  local out = vim.system({ root .. "/bin/nrev", "reviewed", "list" }, { cwd = tmp, text = true }):wait()
  return (out.stdout or ""):find("src/f.txt\t" .. sha, 1, true) ~= nil
end, 100)
assert(written, "reviewed row not written to db")

vim.cmd("DiffviewClose")
vim.cmd("DiffviewOpen")
local restored = vim.wait(5000, function()
  local v = lib.get_current_view()
  if not v or not v.files then
    return false
  end
  for _, file in v.files:iter() do
    if file.path == "src/f.txt" and file.reviewed then
      return true
    end
  end
  return false
end, 100)
assert(restored, "reviewed flag not restored after reopen")

local old_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("^diffview://") then
    old_buf = b
  end
end
assert(old_buf, "no diffview old-side buffer found")
local win = vim.fn.win_findbuf(old_buf)[1]
assert(win, "old-side buffer has no window")
vim.ui.input = function(_, cb)
  cb("old side comment")
end
vim.api.nvim_set_current_win(win)
require("nrev").add()
local old_written = vim.wait(5000, function()
  local out = vim.system({ root .. "/bin/nrev", "list", "--json", "--status", "all" }, { cwd = tmp, text = true }):wait()
  local s = out.stdout or ""
  return s:find("old side comment", 1, true) ~= nil and s:find('"side":"old"', 1, true) ~= nil
end, 100)
assert(old_written, "old-side comment not written with side=old")
local old_rendered = vim.wait(5000, function()
  return #vim.api.nvim_buf_get_extmarks(old_buf, vim.api.nvim_create_namespace("nrev"), 0, -1, {}) == 1
end, 50)
assert(old_rendered, "old-side extmark not rendered")

print("OK")
