-- Patch view: every file's hunks in one buffer (ui/view/patch.lua)

local h = require("tests.helpers")

describe("patch view", function()
  local patch, lifecycle, config, nav, diff_module
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    local cfg = require("codediff.config")
    cfg.options = vim.deepcopy(cfg.defaults)
    require("codediff.ui.highlights").setup()

    patch = require("codediff.ui.view.patch")
    lifecycle = require("codediff.ui.lifecycle")
    config = require("codediff.config")
    nav = require("codediff.ui.view.navigation")
    diff_module = require("codediff.core.diff")
  end)

  after_each(function()
    if repo then
      repo.cleanup()
      repo = nil
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  local function file(path, status, group)
    return { path = path, status = status, status_symbol = status, group = group or "unstaged" }
  end

  local function entry(path, original, modified, status)
    return {
      file = file(path, status or "M"),
      original = original,
      modified = modified,
      diff = diff_module.compute_diff(original, modified, {}),
    }
  end

  local function index_of(lines, text)
    for i, line in ipairs(lines) do
      if line == text then
        return i
      end
    end
    return nil
  end

  local function marks_on(built, lnum)
    local hls = {}
    for _, m in ipairs(built.marks) do
      if m.line == lnum - 1 then
        hls[#hls + 1] = m.hl
      end
    end
    table.sort(hls)
    return hls
  end

  -- ==========================================================================
  -- build(): pure content builder
  -- ==========================================================================

  describe("build", function()
    it("emits a header, a hunk header, context and the changed lines with marks", function()
      local original = { "l1", "l2", "l3", "l4", "old", "l6", "l7", "l8", "l9" }
      local modified = { "l1", "l2", "l3", "l4", "new", "l6", "l7", "l8", "l9" }
      local built = patch.build({ entry("src/a.lua", original, modified) }, 3)

      assert.are.same({
        "M  src/a.lua",
        "@@ -2,7 +2,7 @@",
        "l2",
        "l3",
        "l4",
        "old",
        "new",
        "l6",
        "l7",
        "l8",
      }, built.lines)

      assert.are.same({ "CodeDiffPatchHeader" }, marks_on(built, 1))
      assert.are.same({ "CodeDiffPatchHunk" }, marks_on(built, 2))
      assert.are.same({}, marks_on(built, 3))
      assert.are.same({ "CodeDiffCharDelete", "CodeDiffLineDelete" }, marks_on(built, 6))
      assert.are.same({ "CodeDiffCharInsert", "CodeDiffLineInsert" }, marks_on(built, 7))

      -- One section covering the whole buffer, one hunk = the two changed lines
      assert.are.equal(1, #built.sections)
      local section = built.sections[1]
      assert.are.equal(1, section.first)
      assert.are.equal(#built.lines, section.last)
      assert.are.same({ { first = 6, last = 7 } }, section.hunks)

      -- Every line maps back to its file line; deleted lines land on the
      -- modified line that replaced them.
      assert.are.same({ section = 1, side = "modified", lnum = 2, land = 2 }, built.origin[3])
      assert.are.same({ section = 1, side = "original", lnum = 5, land = 5 }, built.origin[6])
      assert.are.same({ section = 1, side = "modified", lnum = 5, land = 5 }, built.origin[7])
      assert.are.equal(5, built.origin[2].land) -- hunk header lands on the first change
      assert.is_nil(built.origin[1].side)
    end)

    it("merges changes whose context touches and separates distant ones", function()
      local original = {}
      for i = 1, 30 do
        original[i] = "line " .. i
      end
      local modified = vim.deepcopy(original)
      modified[5] = "line 5 edited" -- hunk A
      modified[10] = "line 10 edited" -- 4 unchanged lines between: merged with A (2*3 >= 4)
      modified[25] = "line 25 edited" -- far away: its own hunk
      local built = patch.build({ entry("a.txt", original, modified) }, 3)

      local hunk_headers = {}
      for _, line in ipairs(built.lines) do
        if line:match("^@@") then
          hunk_headers[#hunk_headers + 1] = line
        end
      end
      assert.are.same({ "@@ -2,12 +2,12 @@", "@@ -22,7 +22,7 @@" }, hunk_headers)
      assert.are.equal(3, #built.sections[1].hunks)
      assert.are.equal(3, #patch.build({ entry("a.txt", original, modified) }, 3).sections[1].hunks)
    end)

    it("separates files with a blank line and keeps explorer order", function()
      local built = patch.build({
        entry("b.txt", { "x" }, { "y" }),
        entry("a.txt", { "x" }, { "z" }),
      }, 3)
      assert.are.equal(1, index_of(built.lines, "M  b.txt"))
      local second = index_of(built.lines, "M  a.txt")
      assert.is_truthy(second)
      assert.are.equal("", built.lines[second - 1])
      assert.are.equal(2, #built.sections)
      assert.are.equal(second, built.sections[2].first)
      -- The blank separator belongs to the section above it
      assert.are.equal(1, built.origin[second - 1].section)
    end)

    it("handles whole-file additions and deletions without the diff engine", function()
      local added = {
        file = file("new.txt", "??"),
        original = {},
        modified = { "n1", "n2" },
        diff = { changes = { { original = { start_line = 1, end_line = 1 }, modified = { start_line = 1, end_line = 3 }, inner_changes = {} } } },
      }
      local deleted = {
        file = file("gone.txt", "D"),
        original = { "g1" },
        modified = {},
        diff = { changes = { { original = { start_line = 1, end_line = 2 }, modified = { start_line = 1, end_line = 1 }, inner_changes = {} } } },
      }
      local built = patch.build({ added, deleted }, 3)
      assert.are.same({ "?? new.txt", "@@ -0,0 +1,2 @@", "n1", "n2", "", "D  gone.txt", "@@ -1,1 +0,0 @@", "g1" }, built.lines)
      assert.are.same({ "CodeDiffLineInsert" }, marks_on(built, 3))
      assert.are.same({ "CodeDiffLineDelete" }, marks_on(built, 8))
    end)

    it("shows a note instead of hunks and renames as old -> new", function()
      local conflict = { file = file("c.txt", "!", "conflicts"), original = {}, modified = {}, diff = { changes = {} }, note = "merge conflict" }
      local renamed = {
        file = { path = "new/name.txt", old_path = "old/name.txt", status = "R", status_symbol = "R", group = "staged" },
        original = { "a" },
        modified = { "a" },
        diff = { changes = {} },
      }
      local built = patch.build({ conflict, renamed }, 3)
      assert.are.same({ "!  c.txt", "   merge conflict", "", "R  old/name.txt -> new/name.txt" }, built.lines)
      assert.are.same({ "CodeDiffPatchNote" }, marks_on(built, 2))
      assert.are.same({}, built.sections[1].hunks)
    end)
  end)

  -- ==========================================================================
  -- Explorer session integration
  -- ==========================================================================

  describe("session", function()
    local function open_explorer()
      repo = h.create_temp_git_repo()
      repo.write_file("a.txt", { "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10", "a11", "a12" })
      repo.write_file("b.txt", { "b1", "b2", "b3" })
      repo.write_file("d-deleted.txt", { "deleted" })
      repo.git("add .")
      repo.git("commit -m initial")
      repo.write_file("a.txt", { "a1 EDIT", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10", "a11", "a12 EDIT" })
      repo.write_file("b.txt", { "b1", "b2 EDIT", "b3" })
      repo.write_file("c-untracked.txt", { "untracked" })
      vim.fn.delete(repo.path("d-deleted.txt"))

      vim.cmd("edit " .. repo.dir .. "/a.txt")
      require("codediff.commands").vscode_diff({ fargs = {} })

      local tabpage, session, explorer
      local ok = vim.wait(8000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local s, e = lifecycle.get_session(tp), lifecycle.get_explorer(tp)
          if s and e and e.current_file_path == "a.txt" and s.stored_diff_result and #(s.stored_diff_result.changes or {}) == 2 then
            tabpage, session, explorer = tp, s, e
            return true
          end
        end
        return false
      end, 50)
      assert.is_true(ok, "explorer session did not open")
      return tabpage, session, explorer
    end

    local function wait_for_patch(tabpage)
      local session = lifecycle.get_session(tabpage)
      local ok = vim.wait(8000, function()
        return session.patch ~= nil and #session.patch.sections > 0
      end, 50)
      assert.is_true(ok, "patch view did not build")
      return session.patch
    end

    local function patch_lines(state)
      return vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
    end

    it("lists every file in explorer order in one buffer", function()
      local tabpage, session = open_explorer()
      assert.is_true(patch.enable(tabpage))
      local state = wait_for_patch(tabpage)

      assert.are.equal(state.bufnr, vim.api.nvim_win_get_buf(session.modified_win))
      assert.are.equal("inline", session.layout)
      assert.is_false(vim.bo[state.bufnr].modifiable)

      local lines = patch_lines(state)
      local a = index_of(lines, "M  a.txt")
      assert.is_truthy(
        a and index_of(lines, "M  b.txt") and index_of(lines, "?? c-untracked.txt") and index_of(lines, "D  d-deleted.txt"),
        "missing a file header: " .. table.concat(lines, "\n")
      )
      assert.are.equal(4, #state.sections)
      -- Same order as the explorer's own file list (git status order: untracked last)
      local explorer_files = require("codediff.ui.explorer.refresh").get_all_files(lifecycle.get_explorer(tabpage).tree)
      for i, f in ipairs(explorer_files) do
        assert.are.equal(f.data.path, state.sections[i].file.path)
      end
      -- Deleted original line first, then its replacement, then context
      assert.are.same({ "@@ -1,4 +1,4 @@", "a1", "a1 EDIT", "a2", "a3", "a4" }, vim.list_slice(lines, a + 1, a + 6))
      assert.is_truthy(index_of(lines, "untracked"))
      assert.is_truthy(index_of(lines, "deleted"))

      -- ]c/[c walk the hunks of the patch buffer (2 in a.txt, 1 in b.txt, whole-file for the rest)
      vim.api.nvim_set_current_win(session.modified_win)
      vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })
      assert.is_true(nav.next_hunk())
      assert.are.equal(state.sections[1].hunks[1].first, vim.api.nvim_win_get_cursor(0)[1])
      assert.is_true(nav.next_hunk())
      assert.are.equal(state.sections[1].hunks[2].first, vim.api.nvim_win_get_cursor(0)[1])
      assert.is_true(nav.next_hunk())
      assert.are.equal(state.sections[2].hunks[1].first, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("selects the file under the cursor in the explorer, and jumps from the explorer", function()
      local tabpage, session, explorer = open_explorer()
      assert.is_true(patch.enable(tabpage))
      local state = wait_for_patch(tabpage)
      assert.are.equal("a.txt", explorer.current_file_path)

      vim.api.nvim_set_current_win(session.modified_win)
      vim.api.nvim_win_set_cursor(session.modified_win, { state.sections[2].first + 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.bufnr })
      assert.are.equal("b.txt", explorer.current_file_path)
      assert.are.equal("unstaged", explorer.current_file_group)
      local node = explorer.tree:get_node(vim.api.nvim_win_get_cursor(explorer.winid)[1])
      assert.are.equal("b.txt", node.data.path)

      -- Explorer selection jumps to the section instead of opening a diff
      explorer.on_file_select(state.sections[4].file)
      assert.are.equal(state.bufnr, vim.api.nvim_win_get_buf(session.modified_win))
      assert.are.equal(state.sections[4].first, vim.api.nvim_win_get_cursor(session.modified_win)[1])
      assert.are.equal(state.sections[4].file.path, explorer.current_file_path)
    end)

    it("restores the per-file diff on disable and lands on the chosen line when drilling in", function()
      local tabpage, session, explorer = open_explorer()
      assert.are.equal("side-by-side", session.layout)
      assert.is_true(patch.enable(tabpage))
      local state = wait_for_patch(tabpage)

      -- Drill into a.txt's second hunk ("a12 EDIT" is modified line 12)
      local lines = patch_lines(state)
      local target = index_of(lines, "a12 EDIT")
      vim.api.nvim_set_current_win(session.modified_win)
      vim.api.nvim_win_set_cursor(session.modified_win, { target, 0 })
      patch.open_at_cursor(tabpage)

      assert.is_nil(session.patch)
      local ok = vim.wait(8000, function()
        local mod_buf = session.modified_bufnr
        return mod_buf
          and vim.api.nvim_buf_is_valid(mod_buf)
          and vim.api.nvim_buf_get_name(mod_buf):match("a%.txt$") ~= nil
          and session.layout == "side-by-side"
          and session.original_win ~= session.modified_win
          and #(session.stored_diff_result.changes or {}) == 2
      end, 50)
      assert.is_true(ok, "per-file diff did not come back")
      assert.are.equal("a.txt", explorer.current_file_path)
      assert.are.equal(12, vim.api.nvim_win_get_cursor(session.modified_win)[1])
      assert.is_false(vim.api.nvim_buf_is_valid(state.bufnr), "patch buffer should be wiped")
    end)

    it("survives a per-file diff that finishes loading after it was enabled", function()
      repo = h.create_temp_git_repo()
      repo.write_file("a.txt", { "a1", "a2" })
      repo.write_file("b.txt", { "b1", "b2" })
      repo.git("add .")
      repo.git("commit -m initial")
      repo.write_file("a.txt", { "a1 EDIT", "a2" })
      repo.write_file("b.txt", { "b1 EDIT", "b2" })

      vim.cmd("edit " .. repo.dir .. "/a.txt")
      require("codediff.commands").vscode_diff({ fargs = {} })
      -- Enable as soon as the explorer exists, while a.txt's diff is still loading
      local tabpage, session
      local ok = vim.wait(8000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local s, e = lifecycle.get_session(tp), lifecycle.get_explorer(tp)
          if s and e and e.current_file_path then
            tabpage, session = tp, s
            return true
          end
        end
        return false
      end, 10)
      assert.is_true(ok, "explorer session did not open")
      assert.is_true(patch.enable(tabpage))
      local state = wait_for_patch(tabpage)

      -- Let any stale per-file render finish, then check the patch view is untouched
      vim.wait(1000)
      assert.is_true(patch.is_active(tabpage))
      assert.are.equal(state.bufnr, vim.api.nvim_win_get_buf(session.modified_win))
      assert.are.equal(state.bufnr, session.modified_bufnr)
      assert.are.equal(2, #state.sections)
    end)

    it("toggles with the view keymap and stays off after the explorer refreshes", function()
      local tabpage, session, explorer = open_explorer()
      vim.api.nvim_set_current_win(explorer.winid)
      assert.is_true(patch.toggle(tabpage))
      wait_for_patch(tabpage)
      assert.is_true(patch.is_active(tabpage))

      -- A refresh-driven re-selection rebuilds instead of opening a diff
      local first_generation = session.patch.generation
      explorer.on_file_select(vim.deepcopy(explorer.current_selection), { no_jump = true })
      assert.is_true(patch.is_active(tabpage))
      assert.are.equal(first_generation + 1, session.patch.generation)
      wait_for_patch(tabpage)

      assert.is_true(patch.toggle(tabpage))
      assert.is_false(patch.is_active(tabpage))
    end)
  end)
end)
