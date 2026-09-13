-- Patch view: every changed file's hunks in one scrollable buffer.
--
-- Explorer mode only. While active, the diff window shows a single scratch
-- buffer with a header per file (in explorer order) followed by that file's
-- hunks plus a few context lines, rendered like a unified patch but with
-- codediff's line/char highlights instead of +/- prefixes. Moving the cursor
-- selects the file under it in the explorer; selecting a file in the explorer
-- jumps to its section; <CR> on a hunk leaves the patch view and opens that
-- file's regular diff at the same line.
--
-- The view is read-only and deliberately decoupled from the per-file session
-- model: the session's buffers point at the patch buffer and an empty scratch
-- buffer, paths are empty and there is no revision, so hunk staging/discard
-- and the other per-file actions bail out (the keymaps that would misbehave
-- are overridden in apply_keymaps). `]c`/`[c` keep working through a
-- synthetic diff result whose ranges are patch-buffer lines.
local M = {}

local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local compat = require("codediff.core.compat")

M.ns = vim.api.nvim_create_namespace("codediff-patch")

-- How many `git show` processes may run at once while loading.
local LOAD_CONCURRENCY = 8

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CodeDiffPatchHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffPatchHunk", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffPatchNote", { link = "Comment", default = true })
end

local function augroup_name(tabpage)
  return "codediff_patch_" .. tabpage
end

-- ============================================================================
-- Pure builder (no buffer access): entries -> lines + marks + line map
-- ============================================================================

---@class PatchEntry
---@field file table explorer file data (path, old_path, status, status_symbol, group)
---@field original string[] lines of the original side ({} when the side does not exist)
---@field modified string[] lines of the modified side ({} when the side does not exist)
---@field diff table lines_diff from core/diff ({ changes = {...} })
---@field filetype string? language for syntax highlighting
---@field note string? shown instead of hunks (merge conflicts)

-- 1-based UTF-16 column -> 1-based byte column (the diff engine reports UTF-16)
local function utf16_to_byte(line, col)
  if col <= 1 then
    return col
  end
  local ok, idx = pcall(compat.str_byteindex_utf16, line, col - 1)
  if ok then
    return idx + 1
  end
  return col
end

-- Byte ranges ({start0, end0_exclusive}) of the char-level changes that touch
-- line `lnum` on `side` ("original"|"modified").
local function char_ranges(inner_changes, side, lnum, text)
  local out = {}
  for _, inner in ipairs(inner_changes or {}) do
    local r = inner[side]
    local empty = r and r.start_line == r.end_line and r.start_col == r.end_col
    if r and not empty and r.start_line <= lnum and r.end_line >= lnum then
      local s = r.start_line == lnum and utf16_to_byte(text, r.start_col) or 1
      local e = r.end_line == lnum and (utf16_to_byte(text, r.end_col) - 1) or #text
      s = math.max(1, math.min(s, #text + 1))
      e = math.min(e, #text)
      if e >= s then
        out[#out + 1] = { s - 1, e }
      end
    end
  end
  return out
end

-- Split a file's changes into hunks: consecutive changes whose context
-- windows touch or overlap end up in the same hunk (git's grouping rule).
local function group_changes(changes, context)
  local groups = {}
  local current
  for _, change in ipairs(changes) do
    local prev = current and current[#current]
    if prev and change.modified.start_line - prev.modified.end_line <= 2 * context then
      current[#current + 1] = change
    else
      current = { change }
      groups[#groups + 1] = current
    end
  end
  return groups
end

local function header_text(file)
  local symbol = file.status_symbol or file.status or ""
  local path = file.path or ""
  if file.old_path and file.old_path ~= file.path then
    path = file.old_path .. " -> " .. path
  end
  return string.format("%-2s %s", symbol, path)
end

---Build the patch buffer content for a list of entries.
---@param entries PatchEntry[]
---@param context number context lines around each hunk
---@return table { lines, marks, sections, origin }
---  marks[i]     = { line, col?, end_col?, hl, eol?, priority }  (0-based, end_col exclusive)
---  sections[i]  = { file, entry, first, last, hunks = { { first, last } } }  (1-based buffer lines)
---  origin[lnum] = { section = i, land = modified line to open the file at,
---                   side = "original"|"modified"|nil, lnum = file line on that side }
function M.build(entries, context)
  local lines, marks, sections, origin = {}, {}, {}, {}
  local line_priority = config.options.diff.highlight_priority

  local function emit(text, section, land, side, lnum)
    lines[#lines + 1] = text
    origin[#lines] = { section = section, land = land, side = side, lnum = lnum }
    return #lines
  end

  local function mark_line(lnum, hl)
    marks[#marks + 1] = { line = lnum - 1, hl = hl, eol = true, priority = line_priority }
  end

  local function mark_chars(lnum, ranges, hl)
    for _, r in ipairs(ranges) do
      marks[#marks + 1] = { line = lnum - 1, col = r[1], end_col = r[2], hl = hl, priority = line_priority + 100 }
    end
  end

  for index, entry in ipairs(entries) do
    if index > 1 then
      emit("", index - 1)
    end
    local section = { file = entry.file, entry = entry, hunks = {} }
    sections[index] = section
    section.first = emit(header_text(entry.file), index)
    mark_line(section.first, "CodeDiffPatchHeader")

    if entry.note then
      mark_line(emit("   " .. entry.note, index), "CodeDiffPatchNote")
    end

    local original, modified = entry.original, entry.modified
    local changes = (entry.diff and entry.diff.changes) or {}

    -- Unchanged lines are identical on both sides; take them from the modified side.
    local function emit_context(from, to)
      for lnum = from, to do
        emit(modified[lnum] or "", index, lnum, "modified", lnum)
      end
    end

    for _, group in ipairs(group_changes(changes, context)) do
      local first, last = group[1], group[#group]
      local before = math.min(context, first.modified.start_line - 1)
      local after = math.min(context, #modified - (last.modified.end_line - 1))
      local orig_count, mod_count = before + after, before + after
      for i, change in ipairs(group) do
        orig_count = orig_count + (change.original.end_line - change.original.start_line)
        mod_count = mod_count + (change.modified.end_line - change.modified.start_line)
        if i > 1 then
          local gap = change.modified.start_line - group[i - 1].modified.end_line
          orig_count, mod_count = orig_count + gap, mod_count + gap
        end
      end
      local orig_start = first.original.start_line - before
      local mod_start = first.modified.start_line - before
      if orig_count == 0 then
        orig_start = orig_start - 1
      end
      if mod_count == 0 then
        mod_start = mod_start - 1
      end
      local hunk_header = string.format("@@ -%d,%d +%d,%d @@", orig_start, orig_count, mod_start, mod_count)
      mark_line(emit(hunk_header, index, first.modified.start_line), "CodeDiffPatchHunk")

      emit_context(first.modified.start_line - before, first.modified.start_line - 1)
      for i, change in ipairs(group) do
        if i > 1 then
          emit_context(group[i - 1].modified.end_line, change.modified.start_line - 1)
        end
        local hunk = { first = #lines + 1 }
        for lnum = change.original.start_line, change.original.end_line - 1 do
          local text = original[lnum] or ""
          local buf_lnum = emit(text, index, change.modified.start_line, "original", lnum)
          mark_line(buf_lnum, "CodeDiffLineDelete")
          mark_chars(buf_lnum, char_ranges(change.inner_changes, "original", lnum, text), "CodeDiffCharDelete")
        end
        for lnum = change.modified.start_line, change.modified.end_line - 1 do
          local text = modified[lnum] or ""
          local buf_lnum = emit(text, index, lnum, "modified", lnum)
          mark_line(buf_lnum, "CodeDiffLineInsert")
          mark_chars(buf_lnum, char_ranges(change.inner_changes, "modified", lnum, text), "CodeDiffCharInsert")
        end
        hunk.last = #lines
        if hunk.last >= hunk.first then
          section.hunks[#section.hunks + 1] = hunk
        end
      end
      emit_context(last.modified.end_line, last.modified.end_line + after - 1)
    end
    section.last = #lines
  end

  return { lines = lines, marks = marks, sections = sections, origin = origin }
end

-- Synthetic diff result so ]c/[c (navigation.lua) walk the hunks of the
-- patch buffer. Ranges are patch-buffer lines; original mirrors modified
-- because the inline code paths only read the modified side.
local function synthetic_diff(built)
  local changes = {}
  for _, section in ipairs(built.sections) do
    for _, hunk in ipairs(section.hunks) do
      local range = { start_line = hunk.first, end_line = hunk.last + 1 }
      changes[#changes + 1] = { original = range, modified = range, inner_changes = {} }
    end
  end
  return { changes = changes, moves = {} }
end

-- ============================================================================
-- Syntax highlighting: treesitter captures of the file content, placed on
-- the patch-buffer lines that show the corresponding file lines.
-- ============================================================================

-- wanted[file_lnum] = 0-based patch buffer line
local function syntax_marks(lines, filetype, wanted, priority)
  if not filetype or filetype == "" or #lines == 0 or next(wanted) == nil then
    return {}
  end
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  local source = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then
    return {}
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or #trees == 0 then
    return {}
  end
  local query_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not query_ok or not query then
    return {}
  end

  local min_row, max_row = math.huge, -1
  for file_lnum in pairs(wanted) do
    min_row = math.min(min_row, file_lnum - 1)
    max_row = math.max(max_row, file_lnum - 1)
  end

  local marks = {}
  for id, node in query:iter_captures(trees[1]:root(), source, min_row, max_row + 1) do
    local r1, c1, r2, c2 = node:range()
    local hl = "@" .. query.captures[id]
    for row = r1, r2 do
      local buf_line = wanted[row + 1]
      if buf_line then
        local text = lines[row + 1] or ""
        local sc = row == r1 and c1 or 0
        local ec = row == r2 and c2 or #text
        if ec > sc then
          marks[#marks + 1] = { line = buf_line, col = sc, end_col = ec, hl = hl, priority = priority }
        end
      end
    end
  end
  return marks
end

-- ============================================================================
-- Sources: where each side of a file comes from, and loading them
-- ============================================================================

local function has_staged_copy(explorer, path)
  for _, f in ipairs((explorer.status_result or {}).staged or {}) do
    if f.path == path then
      return true
    end
  end
  return false
end

-- Returns original_src, modified_src, note. A source is { file = abs } or
-- { rev = revision, rel = path }; nil means that side does not exist.
-- Mirrors the revision rules of explorer/render.lua on_file_select.
local function sources_for(explorer, file)
  if file.group == "conflicts" then
    return nil, nil, "merge conflict, open the file to resolve it"
  end
  local git_root = explorer.git_root
  local orig, mod
  if not git_root then
    orig = { file = explorer.dir1 .. "/" .. file.path }
    mod = { file = explorer.dir2 .. "/" .. file.path }
  else
    local base, target = explorer.base_revision, explorer.target_revision
    local old = file.old_path or file.path
    if base and target and target ~= "WORKING" then
      orig, mod = { rev = base, rel = old }, { rev = target, rel = file.path }
    elseif base then
      orig, mod = { rev = base, rel = old }, { file = git_root .. "/" .. file.path }
    elseif file.group == "staged" then
      orig, mod = { rev = "HEAD", rel = old }, { rev = ":0", rel = file.path }
    else
      orig = { rev = has_staged_copy(explorer, file.path) and ":0" or "HEAD", rel = file.path }
      mod = { file = git_root .. "/" .. file.path }
    end
  end
  if file.status == "??" or file.status == "A" then
    orig = nil
  elseif file.status == "D" then
    mod = nil
  end
  return orig, mod, nil
end

local function loaded_buffer(abs_path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == abs_path then
      return bufnr
    end
  end
  return nil
end

-- Working-tree content: the loaded buffer when there is one (unsaved edits
-- count, like the per-file view), the file on disk otherwise.
local function read_file_lines(abs_path)
  local bufnr = loaded_buffer(abs_path)
  if bufnr then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  if vim.fn.filereadable(abs_path) == 1 then
    return vim.fn.readfile(abs_path)
  end
  return {}
end

-- Load one side; done(lines) runs on the main loop.
local function load_source(explorer, src, done)
  if not src then
    done({})
  elseif src.file then
    done(read_file_lines(src.file))
  else
    require("codediff.core.git").get_file_content(src.rev, explorer.git_root, src.rel, function(err, lines)
      vim.schedule(function()
        done((not err and lines) or {})
      end)
    end)
  end
end

local function compute_diff(original, modified)
  if #original == 0 or #modified == 0 then
    -- One side missing: a single whole-file change, no engine call needed.
    return {
      changes = {
        {
          original = { start_line = 1, end_line = #original + 1 },
          modified = { start_line = 1, end_line = #modified + 1 },
          inner_changes = {},
        },
      },
      moves = {},
    }
  end
  return require("codediff.core.diff").compute_diff(original, modified, {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
  })
end

-- Run `jobs` (functions taking a completion callback) with bounded
-- concurrency, then done().
local function run_jobs(jobs, limit, done)
  local next_job, active, remaining = 1, 0, #jobs
  if remaining == 0 then
    return done()
  end
  local function pump()
    while active < limit and next_job <= #jobs do
      local job = jobs[next_job]
      next_job = next_job + 1
      active = active + 1
      job(function()
        active = active - 1
        remaining = remaining - 1
        if remaining == 0 then
          done()
        else
          pump()
        end
      end)
    end
  end
  pump()
end

-- NUL bytes (git output) or NL-in-string (how readfile() reports NUL) in
-- the first lines: treat the file as binary, like `git diff` does.
local function is_binary(lines)
  for i = 1, math.min(#lines, 64) do
    if lines[i]:find("[%z\n]") then
      return true
    end
  end
  return false
end

-- Load both sides of every file and diff them; done(entries) on the main loop.
local function load_entries(explorer, files, done)
  local entries, jobs = {}, {}
  for i, file in ipairs(files) do
    local orig_src, mod_src, note = sources_for(explorer, file)
    local entry = { file = file, original = {}, modified = {}, diff = { changes = {} }, note = note }
    entries[i] = entry
    if not note then
      entry.filetype = vim.filetype.match({ filename = file.path })
      jobs[#jobs + 1] = function(finish)
        load_source(explorer, orig_src, function(original)
          load_source(explorer, mod_src, function(modified)
            if is_binary(original) or is_binary(modified) then
              entry.note = "binary file"
            else
              entry.original, entry.modified = original, modified
              entry.diff = compute_diff(original, modified) or { changes = {} }
            end
            finish()
          end)
        end)
      end
    end
  end
  run_jobs(jobs, LOAD_CONCURRENCY, function()
    done(entries)
  end)
end

-- ============================================================================
-- Explorer helpers
-- ============================================================================

-- All file nodes in explorer order, ignoring folds (hidden groups are not in the tree).
local function collect_files(explorer)
  local tree = explorer.tree
  local files = {}
  local function walk(node)
    if not node:has_children() then
      return
    end
    for _, id in ipairs(node:get_child_ids()) do
      local child = tree:get_node(id)
      if child and child.data then
        if child.data.type == "directory" then
          walk(child)
        elseif not child.data.type then
          files[#files + 1] = child.data
        end
      end
    end
  end
  for _, root in ipairs(tree:get_nodes()) do
    walk(root)
  end
  return files
end

local function same_file(a, b)
  return a ~= nil and b ~= nil and a.path == b.path and a.group == b.group
end

local function section_for(state, file)
  for i, section in ipairs(state.sections) do
    if same_file(section.file, file) then
      return section, i
    end
  end
  return nil
end

local function explorer_line_of(explorer, file)
  if not explorer.bufnr or not vim.api.nvim_buf_is_valid(explorer.bufnr) then
    return nil
  end
  for line = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
    local node = explorer.tree:get_node(line)
    if node and node.data and same_file(node.data, file) then
      return line
    end
  end
  return nil
end

-- Files whose explorer selection opens a real two-sided diff (the others go
-- through show_single_file, which ignores a pending cursor landing).
local function has_diff_view(file)
  return file.group ~= "conflicts" and file.status ~= "??" and file.status ~= "A" and file.status ~= "D"
end

-- ============================================================================
-- State and cursor handling
-- ============================================================================

local function get_state(tabpage)
  local session = lifecycle.get_session(tabpage)
  return session and session.patch or nil, session
end

---@param tabpage? number
---@return boolean
function M.is_active(tabpage)
  return get_state(tabpage or vim.api.nvim_get_current_tabpage()) ~= nil
end

-- The diff window while it shows the patch buffer.
local function patch_window(state)
  local session = lifecycle.get_session(state.tabpage)
  local win = session and session.modified_win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == state.bufnr then
    return win
  end
  return nil
end

local function section_at_cursor(state)
  local win = patch_window(state)
  if not win then
    return nil
  end
  local entry = state.origin[vim.api.nvim_win_get_cursor(win)[1]]
  local section = entry and state.sections[entry.section]
  return section, entry
end

-- Cursor moved inside the patch buffer: select the file under it in the
-- explorer (highlight + explorer cursor; no diff opened, no CodeDiffFileSelect).
---@param tabpage number
function M.follow_cursor(tabpage)
  local state = get_state(tabpage)
  local section = state and (section_at_cursor(state))
  if not section then
    return
  end
  local explorer = state.explorer
  if not explorer.set_current or same_file(section.file, { path = explorer.current_file_path, group = explorer.current_file_group }) then
    return
  end
  explorer.set_current(section.file)
  local line = explorer_line_of(explorer, section.file)
  if line and explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) then
    pcall(vim.api.nvim_win_set_cursor, explorer.winid, { line, 0 })
  end
end

local function jump_to(state, file)
  local section = section_for(state, file)
  local win = patch_window(state)
  if not section or not win then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { section.first, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
end

-- Where the cursor is (file + offset into its section) so a rebuild can put
-- it back even when line numbers shift.
local function cursor_anchor(state)
  local win = patch_window(state)
  if not win then
    return nil
  end
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local entry = state.origin[view.lnum]
  local section = entry and state.sections[entry.section]
  if section then
    return { file = section.file, offset = view.lnum - section.first, index = entry.section, view = view }
  end
  local explorer = state.explorer
  return { file = { path = explorer.current_file_path, group = explorer.current_file_group }, offset = 0, index = 1 }
end

local function restore_cursor(state, anchor)
  local win = patch_window(state)
  if not win or #state.sections == 0 then
    return
  end
  local section = anchor and section_for(state, anchor.file)
  local offset = anchor and anchor.offset or 0
  if not section then
    section = state.sections[math.min(anchor and anchor.index or 1, #state.sections)]
    offset = 0
  end
  local lnum = math.min(section.first + offset, section.last)
  local view = anchor and anchor.view
  vim.api.nvim_win_call(win, function()
    if view then
      vim.fn.winrestview({ lnum = lnum, col = view.col, topline = math.max(1, lnum - (view.lnum - view.topline)) })
    else
      vim.fn.winrestview({ lnum = lnum, col = 0 })
      vim.cmd("normal! zt")
    end
  end)
  M.follow_cursor(state.tabpage)
end

local function render(state, built)
  local bufnr = state.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, built.lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  -- Syntax colors sit just below the diff line highlights so a syntax group
  -- that defines a background cannot hide the insert/delete tint.
  local syntax_priority = config.options.diff.highlight_priority - 1
  local marks = built.marks
  for index, section in ipairs(built.sections) do
    local entry = section.entry
    if entry.filetype then
      local wanted = { original = {}, modified = {} }
      for lnum = section.first, section.last do
        local o = built.origin[lnum]
        if o and o.section == index and o.side then
          wanted[o.side][o.lnum] = wanted[o.side][o.lnum] or (lnum - 1)
        end
      end
      for side, lines in pairs({ original = entry.original, modified = entry.modified }) do
        for _, m in ipairs(syntax_marks(lines, entry.filetype, wanted[side], syntax_priority)) do
          marks[#marks + 1] = m
        end
      end
    end
  end

  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, m.line, m.col or 0, {
      end_row = m.eol and (m.line + 1) or nil,
      end_col = m.eol and 0 or m.end_col,
      hl_group = m.hl,
      hl_eol = m.eol or nil,
      priority = m.priority,
    })
  end

  state.sections, state.origin = built.sections, built.origin
  lifecycle.update_diff_result(state.tabpage, synthetic_diff(built))
end

-- Reload every file and redraw the buffer, keeping the cursor on the same
-- file (and offset into it) when that file is still listed.
---@param tabpage number
function M.rebuild(tabpage)
  local state, session = get_state(tabpage)
  if not state then
    return
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local anchor = cursor_anchor(state)
  local explorer = state.explorer
  load_entries(explorer, collect_files(explorer), function(entries)
    if session.patch ~= state or state.generation ~= generation or not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    local ok, err = xpcall(function()
      render(state, M.build(entries, config.options.diff.compact_context_lines))
      restore_cursor(state, anchor)
    end, debug.traceback)
    if not ok then
      vim.notify("codediff: patch view failed to render: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

-- ============================================================================
-- Keymaps inside the patch buffer
-- ============================================================================

-- Leave the patch view and open the regular diff of the file under the
-- cursor, landing on the same line.
---@param tabpage number
function M.open_at_cursor(tabpage)
  local state = get_state(tabpage)
  if not state then
    return
  end
  local section, entry = section_at_cursor(state)
  if not section then
    return
  end
  M.disable(tabpage, { select = section.file, line = entry.land })
end

-- Open the working-tree file under the cursor in the previous tab (or a
-- new tab before this one), at the line the hunk lands on.
---@param tabpage number
function M.open_in_prev_tab(tabpage)
  local state = get_state(tabpage)
  if not state then
    return
  end
  local section, entry = section_at_cursor(state)
  if not section then
    return
  end
  local explorer = state.explorer
  local abs_path = (explorer.git_root or explorer.dir2) .. "/" .. section.file.path
  if vim.fn.filereadable(abs_path) == 0 then
    vim.notify("codediff: no working-tree file for " .. section.file.path, vim.log.levels.WARN)
    return
  end

  local tabs = vim.api.nvim_list_tabpages()
  local target_tab
  for i, tab in ipairs(tabs) do
    if tab == tabpage and i > 1 then
      target_tab = tabs[i - 1]
    end
  end
  if target_tab then
    vim.api.nvim_set_current_tabpage(target_tab)
  else
    vim.cmd("tabnew")
    vim.cmd("tabmove 0")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  if entry.land then
    pcall(vim.api.nvim_win_set_cursor, 0, { entry.land, 0 })
  end
  if config.options.keymaps.view.close_on_open_in_prev_tab and vim.api.nvim_tabpage_is_valid(tabpage) then
    lifecycle.close(tabpage)
  end
end

local function apply_keymaps(state)
  local km = config.options.keymaps.view
  local ekm = config.options.keymaps.explorer or {}
  local base = { noremap = true, silent = true, nowait = true }
  local function map(lhs, rhs, desc, bufnr)
    if lhs and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", base, { buffer = bufnr, desc = desc }))
    end
  end
  local function unavailable(what)
    return function()
      vim.notify("codediff: " .. what .. " is not available in the patch view", vim.log.levels.INFO)
    end
  end

  local unavailable_here = {
    stage_hunk = "hunk staging",
    unstage_hunk = "hunk unstaging",
    discard_hunk = "discarding hunks",
    diff_get = "diff get",
    diff_put = "diff put",
    align_move = "move alignment",
  }
  for name, what in pairs(unavailable_here) do
    map(km[name], unavailable(what), what .. " (patch view)", state.bufnr)
  end
  -- Layout and compact toggles are tab-wide, so the explorer needs them too.
  for _, bufnr in ipairs({ state.bufnr, state.explorer.bufnr }) do
    map(km.toggle_layout, unavailable("the layout toggle"), "Toggle layout (patch view)", bufnr)
    map(km.toggle_compact, unavailable("compact mode"), "Toggle compact (patch view)", bufnr)
  end

  map(ekm.select, function()
    M.open_at_cursor(state.tabpage)
  end, "Open this file's diff at this line", state.bufnr)
  map(km.open_in_prev_tab, function()
    M.open_in_prev_tab(state.tabpage)
  end, "Open file in previous tab", state.bufnr)
end

-- ============================================================================
-- Enable / disable
-- ============================================================================

---@param tabpage? number
---@return boolean
function M.enable(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  local explorer = lifecycle.get_explorer(tabpage)
  if not session or not explorer or session.mode ~= "explorer" then
    vim.notify("codediff: the patch view needs an explorer session", vim.log.levels.WARN)
    return false
  end
  if session.patch then
    return true
  end
  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    vim.notify("codediff: close the merge conflict view first", vim.log.levels.WARN)
    return false
  end
  if #collect_files(explorer) == 0 then
    vim.notify("codediff: no changes to show", vim.log.levels.INFO)
    return false
  end

  setup_highlights()
  local prev = {
    layout = session.layout,
    compact = session.compact_mode,
    compact_default_applied = session.compact_default_applied,
    reapply_keymaps = session.reapply_keymaps,
  }
  local compact = require("codediff.ui.view.compact")
  if session.compact_mode then
    compact.disable(tabpage)
  end
  if session.layout ~= "inline" and not require("codediff.ui.view.toggle").normalize_inline_layout(tabpage) then
    return false
  end
  local win = session.modified_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  -- Detach the per-file buffers from the session.
  local auto_refresh = require("codediff.ui.auto_refresh")
  for _, bufnr in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      auto_refresh.disable(bufnr)
      lifecycle.clear_highlights(bufnr)
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "codediff-patch"
  pcall(vim.api.nvim_buf_set_name, bufnr, "CodeDiff Patch [" .. tabpage .. "]")
  local empty_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[empty_buf].buftype = "nofile"

  vim.api.nvim_win_set_buf(win, bufnr)
  require("codediff.ui.view.welcome_window").sync(win)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local path = require("codediff.core.path")
  session.single_side = nil
  lifecycle.update_buffers(tabpage, empty_buf, bufnr)
  lifecycle.update_paths(tabpage, path.empty(), path.empty())
  lifecycle.update_revisions(tabpage, nil, nil)
  lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
  lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(empty_buf), vim.api.nvim_buf_get_changedtick(bufnr))
  -- compact.refresh() runs after every keymap setup; keep it from folding
  -- the patch buffer on behalf of the "open in compact mode" default.
  session.compact_default_applied = true

  local state = { tabpage = tabpage, bufnr = bufnr, empty_bufnr = empty_buf, explorer = explorer, prev = prev, sections = {}, origin = {}, generation = 0 }
  session.patch = state

  -- Keymaps: the regular view set (quit, ]c/[c, ]f/[f, explorer toggles, help,
  -- ...) plus the patch-specific overrides, re-applied whenever the session
  -- re-applies its own (TabEnter).
  require("codediff.ui.view.keymaps").setup_all_keymaps(tabpage, empty_buf, bufnr, true)
  apply_keymaps(state)
  session.reapply_keymaps = function()
    if prev.reapply_keymaps then
      pcall(prev.reapply_keymaps)
    end
    if session.patch == state then
      apply_keymaps(state)
    end
  end

  local group = vim.api.nvim_create_augroup(augroup_name(tabpage), { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.follow_cursor(tabpage)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      if session.patch == state then
        M.disable(tabpage, { rerender = false })
      end
    end,
  })

  require("codediff.ui.layout").arrange(tabpage)
  M.rebuild(tabpage)
  return true
end

-- Leave the patch view. By default the current file's regular diff is
-- reopened (`opts.select`/`opts.line` pick a file and a modified-side line
-- to land on instead); `opts.rerender = false` only tears the state down,
-- for callers that replace the window content themselves.
---@param tabpage? number
---@param opts? { rerender?: boolean, select?: table, line?: number }
---@return boolean
function M.disable(tabpage, opts)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  opts = opts or {}
  local state, session = get_state(tabpage)
  if not state then
    return false
  end
  local explorer = state.explorer
  session.patch = nil
  session.reapply_keymaps = state.prev.reapply_keymaps
  session.compact_default_applied = state.prev.compact_default_applied
  pcall(vim.api.nvim_del_augroup_by_name, augroup_name(tabpage))
  -- The patch buffer is wiped as soon as the window shows something else;
  -- keep the session pointing at a buffer that stays valid until then.
  if vim.api.nvim_buf_is_valid(state.empty_bufnr) then
    lifecycle.update_buffers(tabpage, state.empty_bufnr, state.empty_bufnr)
  end

  if opts.rerender == false then
    return true
  end

  if state.prev.layout == "side-by-side" then
    require("codediff.ui.view.toggle").normalize_side_by_side_layout(tabpage)
  end
  local explorer_module = require("codediff.ui.explorer")
  if opts.select then
    if opts.line and has_diff_view(opts.select) then
      session.pending_cursor_landing = opts.line
    end
    explorer.on_file_select(opts.select)
  elseif explorer.current_selection then
    explorer_module.rerender_current(explorer)
  else
    local files = collect_files(explorer)
    if files[1] then
      explorer.on_file_select(files[1])
    else
      explorer_module.show_welcome_page(explorer)
    end
  end
  require("codediff.ui.layout").arrange(tabpage)
  if state.prev.compact then
    require("codediff.ui.view.compact").enable(tabpage)
  end
  return true
end

---@param tabpage? number
---@return boolean
function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if M.is_active(tabpage) then
    return M.disable(tabpage)
  end
  return M.enable(tabpage)
end

-- ============================================================================
-- Explorer hooks (called from explorer/render.lua while the view is active)
-- ============================================================================

-- A file was selected in the explorer. Refresh-driven selections (no_jump)
-- and forced re-renders rebuild the buffer; user selections jump to the
-- file's section.
---@param tabpage number
---@param file table explorer file data
---@param opts? { force?: boolean, no_jump?: boolean }
function M.select(tabpage, file, opts)
  local state = get_state(tabpage)
  if not state then
    return
  end
  if opts and (opts.force or opts.no_jump) then
    M.rebuild(tabpage)
  else
    jump_to(state, file)
  end
end

-- The explorer wants to show its welcome page. Keeps the patch view up
-- (rebuilt) while files remain and returns true; otherwise leaves the
-- patch view and returns false so the welcome page can take the window.
---@param tabpage number
---@return boolean
function M.on_welcome_page(tabpage)
  local state = get_state(tabpage)
  if not state then
    return false
  end
  if #collect_files(state.explorer) > 0 then
    M.rebuild(tabpage)
    return true
  end
  M.disable(tabpage, { rerender = false })
  return false
end

return M
