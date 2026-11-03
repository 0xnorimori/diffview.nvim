local RevType = require("diffview.vcs.rev").RevType

local api = vim.api

local M = {}

M.FILLER = "╱"

local ns = api.nvim_create_namespace("diffview_fill")
local buffers = setmetatable({}, { __mode = "k" })

local function short(rev)
  if rev.type == RevType.LOCAL then
    return "Working tree"
  end
  if rev.type == RevType.STAGE then
    return "Index"
  end
  return rev.commit and rev.commit:sub(1, 7) or "?"
end

function M.labels(view)
  return view.review_labels or { left = short(view.left), right = short(view.right) }
end

function M.message(view, symbol)
  local labels = M.labels(view)
  if symbol == "a" then
    local left = labels.left == "Index" and "the index" or labels.left:gsub("^Before ", "")
    return "New file — nothing before " .. left
  end
  return "Deleted in " .. (labels.right == "Working tree" and "the working tree" or labels.right)
end

local function filler_buf(win)
  local buf = buffers[win]
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  buffers[win] = buf
  return buf
end

function M.show(win, text, diff)
  local buf = filler_buf(win)
  if api.nvim_win_get_buf(win.id) ~= buf then
    api.nvim_win_set_buf(win.id, buf)
    if diff ~= false then
      api.nvim_win_call(win.id, function()
        vim.cmd("diffthis")
      end)
    end
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { " " .. text .. " ", "DiffviewFillMessage" } },
    virt_text_pos = "overlay",
  })
end

---@param view DiffView
function M.apply(view)
  local layout = view.cur_layout
  local wins = layout and layout.windows or {}
  if #wins < 2 then
    return
  end
  for _, win in ipairs(wins) do
    if win:is_valid() then
      if win.file and win.file.nulled then
        M.show(win, M.message(view, win.file.symbol))
      end
      api.nvim_win_call(win.id, function()
        vim.opt_local.fillchars:append({ diff = M.FILLER })
      end)
    end
  end
end

return M
