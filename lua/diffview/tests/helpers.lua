local assert = require("luassert")
local async = require("diffview.async")

local await, pawait = async.await, async.pawait

local M = {}

function M.eq(a, b)
  if a == nil or b == nil then return assert.are.equal(a, b) end
  return assert.are.same(a, b)
end

function M.neq(a, b)
  if a == nil or b == nil then return assert.are_not.equal(a, b) end
  return assert.are_not.same(a, b)
end

---@param test_func function
function M.async_test(test_func)
  local afunc = async.void(test_func)

  return function(...)
    local ok, err = pawait(afunc(...))
    await(async.scheduler())

    if not ok then
      error(err)
    end
  end
end

M.nrev_bin = vim.fn.getcwd() .. "/bin/nrev"

function M.git(dir, ...)
  local cmd = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
  return vim.trim(vim.fn.system(vim.list_extend(cmd, { ... })))
end

function M.nrev(dir, ...)
  local out = vim.system(vim.list_extend({ M.nrev_bin }, { ... }), { cwd = dir, text = true }):wait()
  assert(out.code == 0, out.stderr)
  return out.stdout
end

function M.wait_for(pred)
  assert(vim.wait(5000, pred, 20), "condition not met in time")
end

function M.make_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  M.git(repo, "init", "-q")
  vim.fn.writefile({ "package a", "func A() {}" }, repo .. "/a.go")
  vim.fn.writefile({ "package a" }, repo .. "/a_test.go")
  M.git(repo, "add", ".")
  M.git(repo, "commit", "-q", "-m", "init")
  vim.fn.writefile({ "package a", "func A() int { return 1 }", "func B() {}" }, repo .. "/a.go")
  vim.fn.writefile({ "package a", "func TestA() {}" }, repo .. "/a_test.go")
  vim.fn.writefile({ "package a" }, repo .. "/b_test.go")
  vim.fn.writefile({ "one", "two", "three" }, repo .. "/new.txt")
  return repo
end

M.nrev_it = vim.fn.executable(M.nrev_bin) == 1 and it or pending

return M
