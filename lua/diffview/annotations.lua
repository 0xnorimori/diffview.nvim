local oop = require("diffview.oop")

local M = {}

---@class AnnotationEntry
---@field file string
---@field lnum integer
---@field side "a"|"b"|"file"
---@field type "add"|"remove"|"context"|"file"
---@field text string
---@field line_content string
---@field extmark_id? integer
---@field extmark_bufnr? integer

---@class AnnotationStore : diffview.Object
local AnnotationStore = oop.create_class("AnnotationStore")

function AnnotationStore:init()
  self.entries = {}
end

---@param entry AnnotationEntry
function AnnotationStore:add(entry)
  table.insert(self.entries, entry)
end

---@param file string
---@param lnum integer
---@param side "a"|"b"|"file"
---@return AnnotationEntry?
function AnnotationStore:remove(file, lnum, side)
  for i, e in ipairs(self.entries) do
    if e.file == file and e.lnum == lnum and e.side == side then
      return table.remove(self.entries, i)
    end
  end
  return nil
end

---@param file string
---@return AnnotationEntry[]
function AnnotationStore:get_for_file(file)
  local result = {}
  for _, e in ipairs(self.entries) do
    if e.file == file then
      table.insert(result, e)
    end
  end
  return result
end

---@return AnnotationEntry[]
function AnnotationStore:get_all()
  local sorted = vim.list_extend({}, self.entries)
  table.sort(sorted, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.lnum < b.lnum
  end)
  return sorted
end

---@return boolean
function AnnotationStore:has_any()
  return #self.entries > 0
end

---@return integer
function AnnotationStore:count()
  return #self.entries
end

---@param file string
---@return integer
function AnnotationStore:count_for_file(file)
  local n = 0
  for _, e in ipairs(self.entries) do
    if e.file == file then n = n + 1 end
  end
  return n
end

local type_export_map = {
  add = "(+)",
  remove = "(-)",
  context = "(context)",
  file = "(file-level)",
}

---@param path string
function AnnotationStore:export(path)
  local lines = {}
  for _, e in ipairs(self:get_all()) do
    if e.type == "file" then
      table.insert(lines, string.format("## %s %s", e.file, type_export_map[e.type]))
    else
      table.insert(lines, string.format("## %s:%d %s", e.file, e.lnum, type_export_map[e.type] or "(context)"))
    end
    for tl in e.text:gmatch("[^\n]*") do
      if tl:match("^## ") then
        table.insert(lines, "\\## " .. tl:sub(4))
      else
        table.insert(lines, tl)
      end
    end
    table.insert(lines, "")
  end

  local f = io.open(path, "w")
  if f then
    f:write(table.concat(lines, "\n"))
    f:close()
  end
end

local type_import_map = {
  ["(+)"] = { type = "add", side = "b" },
  ["(-)"] = { type = "remove", side = "a" },
  ["(context)"] = { type = "context", side = "b" },
  ["(file-level)"] = { type = "file", side = "file" },
}

---@param path string
function AnnotationStore:import(path)
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return end

  local cur_file, cur_lnum, cur_type, cur_side
  local text_lines = {}

  local function flush()
    if not cur_file then return end
    local text = vim.trim(table.concat(text_lines, "\n"))
    if text ~= "" then
      self:add({
        file = cur_file,
        lnum = cur_lnum,
        side = cur_side,
        type = cur_type,
        text = text,
        line_content = "",
      })
    end
    cur_file = nil
    text_lines = {}
  end

  for line in content:gmatch("[^\n]*") do
    if line:match("^\\## ") then
      table.insert(text_lines, "## " .. line:sub(5))
    else
      local header = line:match("^## (.+)")
      if header then
        flush()
        local file_part, marker = header:match("^(.+)%s+(%(.-%))")
        if file_part and marker then
          local info = type_import_map[marker]
          if info then
            cur_type = info.type
            cur_side = info.side
            local file, lnum_str = file_part:match("^(.+):(%d+)$")
            if file and lnum_str then
              cur_file = file
              cur_lnum = tonumber(lnum_str)
            else
              cur_file = file_part
              cur_lnum = 0
            end
          end
        end
      elseif cur_file then
        table.insert(text_lines, line)
      end
    end
  end
  flush()
end

M.AnnotationStore = AnnotationStore

return M
