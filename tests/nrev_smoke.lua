local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.system({ "git", "-C", tmp, "init", "-q" })
local f = tmp .. "/main.go"
vim.fn.writefile({ "package main", "func main() {}" }, f)

local nrev = require("nrev")
nrev.setup({ bin = root .. "/bin/nrev" })

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

nrev.export()
local exported = vim.wait(5000, function()
  return vim.fn.getreg("+"):find("[NOTE]", 1, true) ~= nil
end, 50)
assert(exported, "export register missing open comment: " .. vim.fn.getreg("+"))

vim.api.nvim_win_set_cursor(0, { 2, 0 })
nrev.toggle_resolve()
local resolved = vim.wait(5000, function()
  local rows = vim.b.nrev_comments
  return rows ~= nil and #rows == 1 and rows[1].status == "resolved"
end, 50)
assert(resolved, "comment was not resolved")

nrev.delete()
local deleted = vim.wait(5000, function()
  local rows = vim.b.nrev_comments
  return rows ~= nil and #rows == 0
end, 50)
assert(deleted, "comment was not deleted")

local mode_at_input
vim.ui.input = function(_, cb)
  mode_at_input = vim.fn.mode()
  cb("visual range comment")
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("Vj", "x", false)
nrev.add()
assert(mode_at_input == "n", "expected normal mode at input time, got " .. tostring(mode_at_input))
local vis_ok = vim.wait(5000, function()
  local out2 = vim.system({ root .. "/bin/nrev", "list", "--json", "--status", "open" }, { cwd = tmp, text = true }):wait()
  local s2 = out2.stdout or ""
  return s2:find("visual range comment", 1, true) ~= nil
    and s2:find('"line_start":1', 1, true) ~= nil
    and s2:find('"line_end":2', 1, true) ~= nil
end, 100)
assert(vis_ok, "visual-range comment not stored with 1..2 range")

print("OK")
