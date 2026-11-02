local RevType = require("diffview.vcs.rev").RevType

local M = {}

M.tests = {
  "*_test.go",
  "*Tests.swift",
  "*Test.swift",
  "*_spec.lua",
  "*.test.{ts,tsx,js,jsx}",
  "*.spec.{ts,tsx,js,jsx}",
  "test_*.py",
  "*_test.py",
  "test/",
  "tests/",
  "__tests__/",
  "testdata/",
}

M.generated = {
  "go.sum",
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
  "Package.resolved",
  "Cargo.lock",
  "*-lock.json",
  "*-lock.yaml",
}

local HEADER = "^// Code generated .* DO NOT EDIT%.$"
local HEADER_LINES = 5

local compiled = {}

local function matcher(pattern)
  local m = compiled[pattern]
  if not m then
    local dir = pattern:sub(-1) == "/"
    local glob = dir and pattern:sub(1, -2) or pattern
    m = { lpeg = vim.glob.to_lpeg(glob), dir = dir, full = not dir and glob:find("/", 1, true) ~= nil }
    compiled[pattern] = m
  end
  return m
end

local function matches(pattern, path)
  local m = matcher(pattern)
  if m.full then
    return m.lpeg:match(path) ~= nil
  end
  local segments = vim.split(path, "/", { plain = true })
  if not m.dir then
    return m.lpeg:match(segments[#segments]) ~= nil
  end
  for i = 1, #segments - 1 do
    if m.lpeg:match(segments[i]) then
      return true
    end
  end
  return false
end

local function any(lists, path)
  for _, list in ipairs(lists) do
    for _, pattern in ipairs(list) do
      if matches(pattern, path) then
        return true
      end
    end
  end
  return false
end

local function generated_header(lines)
  for _, line in ipairs(lines or {}) do
    if line:match(HEADER) then
      return true
    end
  end
  return false
end

---@param path string
---@param info { header?: string[], attrs?: { generated?: boolean, test?: boolean } }
---@param filters table
---@return "test"|"generated"|"code"
function M.kind(path, info, filters)
  local attrs = info.attrs or {}
  if attrs.generated or generated_header(info.header) or any({ M.generated, filters.generated.extend or {} }, path) then
    return "generated"
  end
  if attrs.test or any({ M.tests, filters.tests.extend or {} }, path) then
    return "test"
  end
  return "code"
end

local function read_header(abs)
  local stat = vim.uv.fs_lstat(abs)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local f = io.open(abs, "r")
  if not f then
    return nil
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
    if #lines >= HEADER_LINES then
      break
    end
  end
  f:close()
  return lines
end

local function parse_attrs(stdout)
  local attrs = {}
  local parts = vim.split(stdout or "", "\0", { plain = true })
  for i = 1, #parts - 2, 3 do
    local path, attr, value = parts[i], parts[i + 1], parts[i + 2]
    if value == "set" or value == "true" then
      attrs[path] = attrs[path] or {}
      attrs[path][attr == "linguist-generated" and "generated" or "test"] = true
    end
  end
  return attrs
end

---@param adapter VCSAdapter
---@param files FileEntry[]
---@param cb fun()
function M.apply(adapter, files, cb)
  local filters = require("diffview.config").get_config().file_panel.filters
  local toplevel = adapter.ctx.toplevel
  local paths = vim.tbl_map(function(f)
    return f.path
  end, files)

  local function finish(attrs)
    for _, file in ipairs(files) do
      local rev = file.revs and file.revs.b
      local header = nil
      if rev and (rev.type == RevType.LOCAL or rev.type == RevType.STAGE) then
        header = read_header(toplevel .. "/" .. file.path)
      end
      file.review_kind = M.kind(file.path, { header = header, attrs = attrs[file.path] }, filters)
    end
    cb()
  end

  if #paths == 0 then
    finish({})
    return
  end

  local ok = pcall(vim.system,
    { "git", "-C", toplevel, "check-attr", "-z", "--stdin", "linguist-generated", "diffview-test" },
    { stdin = table.concat(paths, "\0") .. "\0", text = true },
    function(out)
      vim.schedule(function()
        finish(out.code == 0 and parse_attrs(out.stdout) or {})
      end)
    end
  )
  if not ok then
    finish({})
  end
end

return M
