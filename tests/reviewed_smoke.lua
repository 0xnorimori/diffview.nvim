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
vim.fn.writefile({ "line1" }, tmp .. "/f.txt")
sh({ "git", "-C", tmp, "add", "." })
sh({ "git", "-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "add f" })
vim.fn.writefile({ "line1 changed" }, tmp .. "/f.txt")

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

local rev = view.left.commit or view.adapter:head_rev().commit
local written = vim.wait(5000, function()
  local out = vim.system({ root .. "/bin/nrev", "reviewed", "list", "--rev-range", rev }, { cwd = tmp, text = true }):wait()
  return (out.stdout or ""):find("f.txt", 1, true) ~= nil
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
    if file.path == "f.txt" and file.reviewed then
      return true
    end
  end
  return false
end, 100)
assert(restored, "reviewed flag not restored after reopen")

print("OK")
