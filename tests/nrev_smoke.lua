local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.system({ "git", "-C", tmp, "init", "-q" })
local f = tmp .. "/main.go"
vim.fn.writefile({ "package main", "func main() {}" }, f)

local nrev = require("nrev")
nrev.setup({ bin = root .. "/bin/nrev" })

vim.ui.select = function(_, _, cb)
  cb("issue")
end
vim.ui.input = function(_, cb)
  cb("smoke comment")
end

vim.cmd("edit " .. f)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
nrev.add()

local rendered = vim.wait(5000, function()
  local rows = vim.b.nrev_comments
  return rows ~= nil and #rows == 1
end, 50)
assert(rendered, "comment was not rendered")

local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("nrev"), 0, -1, {})
assert(#marks == 1, "expected 1 extmark, got " .. #marks)

local out = vim.system({ root .. "/bin/nrev", "list", "--json", "--status", "open" }, { cwd = tmp, text = true }):wait()
assert(out.stdout and out.stdout:find("smoke comment", 1, true), "db row missing: " .. (out.stdout or ""))

print("OK")
