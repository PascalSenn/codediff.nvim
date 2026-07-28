-- Per-file marks ("viewed" checkmarks) for the explorer panel.
--
-- Marks are per-tabpage and keyed by repo-relative file path (the same
-- path shown in the explorer). The feature is dormant until activated:
-- rows render without a checkmark slot unless `is_active(tabpage)`.
--
-- Public API (all `tabpage` params optional, default current tabpage):
--   activate(tp) / deactivate(tp) / is_active(tp)
--   get(tp) -> string[]            marked paths
--   is_marked(path, tp)
--   set(paths, opts)               replace the whole marked set
--   mark(path, opts) / unmark(path, opts) / toggle(path, opts)
--   clear(opts)
--
-- Mutations re-render the explorer and emit a `CodeDiffMarksChanged` User
-- autocmd with data = { tabpage, marked, changed } unless opts.silent is
-- set (integrations applying remote state use silent to avoid echo).
local M = {}

---@type table<integer, { marked: table<string, true> }>
local state = {}

local function tp_or_current(tabpage)
  return tabpage or vim.api.nvim_get_current_tabpage()
end

local function rerender(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end
  local explorer = lifecycle.get_explorer(tabpage)
  if explorer and explorer.tree then
    pcall(function()
      explorer.tree:render()
    end)
  end
end

---@param tabpage integer
---@param changed table<string, boolean> path -> new marked state
---@param opts? { silent?: boolean }
local function notify(tabpage, changed, opts)
  rerender(tabpage)
  if opts and opts.silent then
    return
  end
  local marked = {}
  for path in pairs(state[tabpage].marked) do
    marked[path] = true
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffMarksChanged",
    modeline = false,
    data = { tabpage = tabpage, marked = marked, changed = changed },
  })
end

function M.activate(tabpage)
  tabpage = tp_or_current(tabpage)
  if not state[tabpage] then
    state[tabpage] = { marked = {} }
    rerender(tabpage)
  end
end

function M.deactivate(tabpage)
  tabpage = tp_or_current(tabpage)
  state[tabpage] = nil
  rerender(tabpage)
end

function M.is_active(tabpage)
  return state[tp_or_current(tabpage)] ~= nil
end

---@return string[]
function M.get(tabpage)
  local s = state[tp_or_current(tabpage)]
  if not s then
    return {}
  end
  local paths = {}
  for path in pairs(s.marked) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  return paths
end

function M.is_marked(path, tabpage)
  local s = state[tp_or_current(tabpage)]
  return s ~= nil and s.marked[path] == true
end

---Replace the entire marked set.
---@param paths string[]
---@param opts? { tabpage?: integer, silent?: boolean }
function M.set(paths, opts)
  opts = opts or {}
  local tabpage = tp_or_current(opts.tabpage)
  M.activate(tabpage)
  local want = {}
  for _, p in ipairs(paths) do
    want[p] = true
  end
  local changed = {}
  for p in pairs(state[tabpage].marked) do
    if not want[p] then
      changed[p] = false
    end
  end
  for p in pairs(want) do
    if not state[tabpage].marked[p] then
      changed[p] = true
    end
  end
  state[tabpage].marked = want
  if next(changed) ~= nil or opts.silent then
    notify(tabpage, changed, opts)
  end
end

---@param path string
---@param opts? { tabpage?: integer, silent?: boolean }
function M.mark(path, opts)
  opts = opts or {}
  local tabpage = tp_or_current(opts.tabpage)
  M.activate(tabpage)
  if state[tabpage].marked[path] then
    return
  end
  state[tabpage].marked[path] = true
  notify(tabpage, { [path] = true }, opts)
end

---@param path string
---@param opts? { tabpage?: integer, silent?: boolean }
function M.unmark(path, opts)
  opts = opts or {}
  local tabpage = tp_or_current(opts.tabpage)
  M.activate(tabpage)
  if not state[tabpage].marked[path] then
    return
  end
  state[tabpage].marked[path] = nil
  notify(tabpage, { [path] = false }, opts)
end

---@param path string
---@param opts? { tabpage?: integer, silent?: boolean }
function M.toggle(path, opts)
  opts = opts or {}
  local tabpage = tp_or_current(opts.tabpage)
  M.activate(tabpage)
  if state[tabpage].marked[path] then
    M.unmark(path, opts)
  else
    M.mark(path, opts)
  end
end

---@param opts? { tabpage?: integer, silent?: boolean }
function M.clear(opts)
  opts = opts or {}
  local tabpage = tp_or_current(opts.tabpage)
  if not state[tabpage] then
    return
  end
  local changed = {}
  for p in pairs(state[tabpage].marked) do
    changed[p] = false
  end
  state[tabpage].marked = {}
  notify(tabpage, changed, opts)
end

-- Default highlights; user overrides win because of `default = true`.
vim.api.nvim_set_hl(0, "CodeDiffMarkViewed", { default = true, link = "DiffAdd" })
vim.api.nvim_set_hl(0, "CodeDiffMarkUnviewed", { default = true, link = "Comment" })

-- Drop state when the codediff session for a tabpage closes.
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeDiffClose",
  group = vim.api.nvim_create_augroup("CodeDiffMarksCleanup", { clear = true }),
  callback = function(ev)
    local tabpage = ev.data and ev.data.tabpage
    if tabpage then
      state[tabpage] = nil
    end
  end,
})

return M
