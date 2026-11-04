local RevType = require("diffview.vcs.rev").RevType

local M = {}

M.DELETED = "deleted"
M.DIRECTORY = "directory"

local function run(cmd, cwd, stdin, cb)
  local ok = pcall(vim.system, cmd, { cwd = cwd, stdin = stdin, text = true }, function(out)
    vim.schedule(function()
      cb(out)
    end)
  end)
  if not ok then
    cb({ code = -1, stdout = "" })
  end
end

local function lines(stdout)
  return vim.split(vim.trim(stdout or ""), "\n", { plain = true, trimempty = true })
end

---@param adapter VCSAdapter
---@param files FileEntry[]
---@param cb fun(ids: table<FileEntry, string>)
function M.content_ids(adapter, files, cb)
  local top = adapter.ctx.toplevel
  local ids = {}
  local locals, objects = {}, {}
  for _, file in ipairs(files) do
    local rev = file.revs and file.revs.b
    if rev and rev.type == RevType.LOCAL then
      local stat = vim.uv.fs_lstat(top .. "/" .. file.path)
      if not stat then
        ids[file] = M.DELETED
      elseif stat.type == "directory" then
        ids[file] = M.DIRECTORY
      else
        locals[#locals + 1] = file
      end
    elseif rev and rev.type == RevType.STAGE then
      objects[#objects + 1] = { file, ":" .. file.path }
    elseif rev and rev.type == RevType.COMMIT then
      objects[#objects + 1] = { file, rev.commit .. ":" .. file.path }
    end
  end

  local pending = 2
  local function done()
    pending = pending - 1
    if pending == 0 then
      cb(ids)
    end
  end

  local function hash_each()
    local left = #locals
    for _, file in ipairs(locals) do
      run({ "git", "hash-object", "--", file.path }, top, nil, function(out)
        if out.code == 0 then
          ids[file] = lines(out.stdout)[1]
        end
        left = left - 1
        if left == 0 then
          done()
        end
      end)
    end
  end

  if #locals == 0 then
    done()
  else
    local paths = vim.tbl_map(function(f)
      return f.path
    end, locals)
    run({ "git", "hash-object", "--stdin-paths" }, top, table.concat(paths, "\n") .. "\n", function(out)
      if out.code ~= 0 then
        hash_each()
        return
      end
      for i, sha in ipairs(lines(out.stdout)) do
        if locals[i] then
          ids[locals[i]] = sha
        end
      end
      done()
    end)
  end

  if #objects == 0 then
    done()
  else
    local specs = vim.tbl_map(function(o)
      return o[2]
    end, objects)
    run({ "git", "cat-file", "--batch-check" }, top, table.concat(specs, "\n") .. "\n", function(out)
      if out.code == 0 then
        for i, line in ipairs(lines(out.stdout)) do
          if objects[i] then
            ids[objects[i][1]] = line:match("^(%x+) ") or M.DELETED
          end
        end
      end
      done()
    end)
  end
end

local function view_is_open(view)
  local ok, lib = pcall(require, "diffview.lib")
  return ok and vim.tbl_contains(lib.views, view)
end

local function key(file)
  return file.kind .. "\0" .. file.path
end

local function entries(view)
  local out = {}
  for _, file in view.files:iter() do
    if file.kind ~= "conflicting" then
      out[#out + 1] = file
    end
  end
  return out
end

local function parse_rows(out)
  local rows = {}
  if out.code ~= 0 then
    return rows
  end
  for _, line in ipairs(lines(out.stdout)) do
    local path, id = line:match("^(.*)\t(.*)$")
    if path then
      rows[path] = rows[path] or {}
      rows[path][id] = true
    end
  end
  return rows
end

local function parse_comments(out)
  local counts, list = {}, {}
  if out.code ~= 0 or not out.stdout or out.stdout == "" then
    return counts, nil
  end
  local ok, comments = pcall(vim.json.decode, out.stdout)
  if ok and type(comments) == "table" then
    for _, c in ipairs(comments) do
      if c.status == "open" then
        counts[c.file] = (counts[c.file] or 0) + 1
      end
      list[#list + 1] = c
    end
  end
  return counts, list
end

local function cwd(view)
  return view.adapter.ctx.toplevel
end

function M.refresh(view)
  local nrev = require("nrev")
  view._nrev_gen = (view._nrev_gen or 0) + 1
  local gen = view._nrev_gen
  nrev.run({ "reviewed", "list" }, cwd(view), function(out)
    local rows = parse_rows(out)
    nrev.run({ "list", "--json", "--status", "all" }, cwd(view), function(cout)
      local counts, list = parse_comments(cout)
      local files = entries(view)
      M.content_ids(view.adapter, files, function(ids)
        if not view_is_open(view) or view._nrev_gen ~= gen then
          return
        end
        local toggled = {}
        for k, t in pairs(view._nrev_toggled or {}) do
          if not t.sent or t.gen == gen then
            toggled[k] = t
          end
        end
        view._nrev_toggled = {}
        local flags = {}
        for _, file in ipairs(files) do
          local id = ids[file]
          local versions = rows[file.path]
          file.content_id = id
          file.reviewed = (versions and id and versions[id]) or false
          file.stale = id ~= nil and versions ~= nil and not file.reviewed
          file.comments = counts[file.path] or 0
          flags[key(file)] = file.reviewed
        end
        view._nrev_rows = rows
        view._nrev_synced = flags
        for _, file in ipairs(files) do
          local t = toggled[key(file)]
          if t and t.flag ~= file.reviewed and (not t.id or t.id == file.content_id) then
            file.reviewed = t.flag
            file.stale = false
          end
        end
        M.sync(view)
        if view.panel then
          view.panel.comments = list or view.panel.comments
          view.panel:refresh_review()
        end
        vim.api.nvim_exec_autocmds("User", {
          pattern = "NrevReviewedRestored",
          data = { tabpage = view.tabpage },
        })
      end)
    end)
  end)
end

local function kept_ids(view, file)
  local kept = {}
  for _, other in ipairs(entries(view)) do
    if other ~= file and other.path == file.path and other.reviewed and other.content_id then
      kept[other.content_id] = true
    end
  end
  return kept
end

function M.sync(view)
  local nrev = require("nrev")
  local snapshot = view._nrev_synced or {}
  local rows = view._nrev_rows or {}
  view._nrev_toggled = view._nrev_toggled or {}
  for _, file in ipairs(entries(view)) do
    local k = key(file)
    local flag = file.reviewed and true or false
    if (snapshot[k] or false) ~= flag then
      view._nrev_toggled[k] = { flag = flag, gen = view._nrev_gen, sent = file.content_id ~= nil, id = file.content_id }
      if file.content_id then
        if flag then
          nrev.run({ "reviewed", "set", file.path, "--content-id", file.content_id }, cwd(view), nil)
          rows[file.path] = rows[file.path] or {}
          rows[file.path][file.content_id] = true
        else
          local kept = kept_ids(view, file)
          for id in pairs(rows[file.path] or {}) do
            if not kept[id] then
              nrev.run({ "reviewed", "unset", file.path, "--content-id", id }, cwd(view), nil)
              rows[file.path][id] = nil
            end
          end
        end
        snapshot[k] = flag
      end
      file.stale = false
    end
  end
  view._nrev_rows = rows
  view._nrev_synced = snapshot
end

function M.counts(view)
  require("nrev").run({ "list", "--json", "--status", "all" }, cwd(view), function(out)
    if not view_is_open(view) then
      return
    end
    local counts, list = parse_comments(out)
    for _, file in ipairs(entries(view)) do
      file.comments = counts[file.path] or 0
    end
    if view.panel then
      view.panel.comments = list or view.panel.comments
      view.panel:render()
      view.panel:redraw()
    end
  end)
end

return M
