---@mod qwahl Collection of pickers utilizing vim.ui.select

local api = vim.api
local ui = vim.ui
local M = {}


local function list_reverse(xs)
  local result = {}
  for i = #xs, 1, -1 do
    table.insert(result, xs[i])
  end
  return result
end


--- Return a formatted path or name for a bufnr.
--- This function can be overridden to customize the formatting of paths to buffers
---
---@param bufnr number
---@return string
function M.format_bufname(bufnr)
  return vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ':.')
end


--- Takes a list of functions, tries each until one succeeds without error.
--- This can be used to create fallbacks, for example, to create a function
--- that uses `lsp_tags` if a LSP client is available and otherwise falls back
--- to `buf_tags`:
---
---     local q = require('qwahl')
---     q.try(q.lsp_tags, q.buf_tags)
function M.try(...)
  for _, fn in ipairs({...}) do
    local ok, _ = pcall(fn)
    if ok then
      return
    end
  end
end


--- Display lines in the current buffer. Jump to line when selected
function M.buf_lines()
  local lines = api.nvim_buf_get_lines(0, 0, -1, true)
  local win = api.nvim_get_current_win()
  local opts = {
    prompt = 'Line: ',
    format_item = function(x)
      return x
    end,
  }
  ui.select(lines, opts, function(result, idx)
    if result then
      api.nvim_win_set_cursor(win, {idx, 0})
      api.nvim_win_call(win, function()
        vim.cmd('normal! zvzz')
      end)
    end
  end)
end


--- Display open buffers. Opens selected buffer in current window.
function M.buffers()
  local bufs = vim.tbl_filter(
    function(b)
      return vim.fn.buflisted(b) == 1 and api.nvim_buf_get_option(b, 'buftype') ~= 'quickfix'
    end,
    api.nvim_list_bufs()
  )
  local format_bufname = function(b)
    local fullname = api.nvim_buf_get_name(b)
    local name
    if #fullname == 0 then
      name = '[No Name] (' .. api.nvim_buf_get_option(b, 'buftype') .. ')'
    else
      name = M.format_bufname(b)
    end
    local modified = api.nvim_buf_get_option(b, 'modified')
    return modified and name .. ' [+]' or name
  end
  local opts = {
    prompt = 'Buffer: ',
    format_item = format_bufname
  }
  ui.select(bufs, opts, function(b)
    if b then
      api.nvim_set_current_buf(b)
    end
  end)
end


---@class lsp_tags.opts
---@field kind nil|string[] filter tags by kind
---@field mode "next"|"prev"|nil Include only tags after/before the cursor
---@field pick_first boolean? Select first result automatically. Defaults to false
---@field on_done function? Callback called after selection/abort


--- Display LSP symbols in current buffer, jump to symbol position when selected.
--- @param opts nil|lsp_tags.opts
function M.lsp_tags(opts)
  opts = opts or {}
  opts.on_done = opts.on_done or function(_) end
  local bufnr = api.nvim_get_current_buf()
  local function kind_matches(symbol)
    if opts.kind == nil then
      return true
    end
    for _, kind in pairs(opts.kind) do
      if symbol.kind == vim.lsp.protocol.SymbolKind[kind] then
        return true
      end
    end
    return false
  end
  local win = api.nvim_get_current_win()
  local lnum = api.nvim_win_get_cursor(win)[1] - 1
  local function include(symbol)
    if kind_matches(symbol) then
      local range = symbol.range or symbol.location.range
      if opts.mode == 'next' then
        return range.start.line > lnum
      elseif opts.mode == 'prev' then
        return range.start.line < lnum
      else
        return true
      end
    end
    return false
  end
  local clients = {}
  for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr })) do
    if client.server_capabilities.documentSymbolProvider then
      table.insert(clients, client)
      break
    end
  end
  assert(next(clients), "Must have a client running to use lsp_tags")

  local num_remaining = #clients
  local items = {}
  local add_items = nil
  local num_root_primitives = 0

  add_items = function(xs, parent)
    for _, x in ipairs(xs) do
      x.__parent = parent
      if include(x) then
        table.insert(items, x)
      end
      if x.children then
        add_items(x.children, x)
      end
    end
  end

  ---@param item lsp.DocumentSymbol|lsp.SymbolInformation
  local function jump(item)
    if not item then
      opts.on_done()
      return
    end
    local range = item.range or item.location.range
    api.nvim_win_set_cursor(win, {
      range.start.line + 1,
      range.start.character
    })
    api.nvim_win_call(win, function()
      vim.cmd('normal! zvzz')
    end)
    opts.on_done(item)
  end

  local function countdown()
    num_remaining = num_remaining - 1
    if num_remaining > 0 then
      return
    end
    if opts.mode and opts.mode == "prev" then
      items = list_reverse(items)
    end
    if opts.pick_first then
      jump(items[1])
      return
    end
    local select_opts = {
      prompt = 'Tag: ',
      format_item = function(item)
        local path = {}
        local parent = item.__parent
        while parent do
          table.insert(path, parent.name)
          parent = parent.__parent
        end
        local kind = vim.lsp.protocol.SymbolKind[item.kind]
        -- Omit the root if there are no non-container symbols on root level
        -- This is for example the case in Java where everything is inside a class
        -- In that case the class name is mostly noise
        if num_root_primitives == 0 and next(path) then
          table.remove(path, #path)
        end
        if next(path) then
          return string.format('[%s] %s: %s', kind, table.concat(list_reverse(path), ' » '), item.name)
        else
          return string.format('[%s] %s', kind, item.name)
        end
      end,
    }
    ui.select(items, select_opts, jump)
  end
  for _, client in ipairs(clients) do
    local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
    params.context = {
      includeDeclaration = true
    }
    client.request("textDocument/documentSymbol", params, function(err, result)
      assert(not err, vim.inspect(err))
      if not result then
        return
      end
      for _, x in pairs(result) do
        -- 6 is Method, the first kind that is not a container
        -- (File = 1; Module = 2; Namespace = 3; Package = 4; Class = 5;)
        if x.kind >= 6 then
          num_root_primitives = num_root_primitives + 1
        end
      end
      add_items(result)
      countdown()
    end)
  end
end


--- Assume inline diffs: Look for `--- a/` markers and show filenames to jump to
local function git_tags()
  local win = api.nvim_get_current_win()
  local lines = api.nvim_buf_get_lines(0, 0, -1, true)
  local candidates = {}
  for lnum, line in pairs(lines) do
    if vim.startswith(line, '--- a/') then
      table.insert(candidates, {
        lnum = lnum,
        line = string.sub(line, 7),
      })
    end
  end
  local opts = {
    prompt = 'Diff: ',
    format_item = function(x) return x.line end
  }
  ui.select(candidates, opts, function(candidate)
    if candidate then
      api.nvim_win_set_cursor(win, {candidate.lnum, 0})
      api.nvim_win_call(win, function()
        vim.cmd('normal! zvzz')
      end)
    end
  end)
end


--- Displays tags ad-hoc generated using a `ctags` executable.
--- Jumps to tag when selected.
function M.buf_tags()
  if vim.bo.filetype == 'git' or vim.bo.filetype == "gitcommit" then
    return git_tags()
  end
  local bufname = api.nvim_buf_get_name(0)
  assert(vim.fn.filereadable(bufname), 'File to generate tags for must be readable')
  local ok, output = pcall(vim.fn.system, {
    'ctags',
    '-f',
    '-',
    '--sort=yes',
    '--excmd=number',
    '--language-force=' .. api.nvim_buf_get_option(0, 'filetype'),
    bufname
  })
  if not ok or api.nvim_get_vvar('shell_error') ~= 0 then
    output = vim.fn.system({'ctags', '-f', '-', '--sort=yes', '--excmd=number', bufname})
  end
  local lines = vim.tbl_filter(
    function(x) return x ~= '' end,
    vim.split(output, '\n')
  )
  local tags = vim.tbl_map(function(x) return vim.split(x, '\t') end, lines)
  local opts = {
    prompt = 'Tag: ',
    format_item = function(xs) return xs and xs[1] or nil end
  }
  local win = api.nvim_get_current_win()
  ui.select(tags, opts, function(tag)
    if not tag then
      return
    end
    local row = tonumber(vim.split(tag[3], ';')[1])
    api.nvim_win_set_cursor(win, {row, 0})
    api.nvim_win_call(win, function()
      vim.cmd('normal! zvzz')
    end)
  end)
end


--- Close quickfix list and show its contents using vim.ui.select.
--- Jump to entry when selected.
function M.quickfix()
  vim.cmd('cclose')
  local items = vim.fn.getqflist()
  local win = api.nvim_get_current_win()
  local opts = {
    prompt = 'Quickfix: ',
    format_item = function(item)
      return M.format_bufname(item.bufnr) .. ': ' .. item.text
    end
  }
  ui.select(items, opts, function(item, idx)
    if not item then
      return
    end
    api.nvim_win_call(win, function()
      vim.cmd('cc ' .. tostring(idx))
      vim.cmd('normal! zvzz')
    end)
  end)
end


--- Show jumplist. Open selected entry in current window and jump to its position.
function M.jumplist()
  local locations = vim.tbl_filter(
    function(loc) return api.nvim_buf_is_valid(loc.bufnr) end,
    vim.fn.getjumplist()[1]
  )
  local opts = {
    prompt = 'Jumplist: ',
    format_item = function(loc)
      local line
      if api.nvim_buf_is_loaded(loc.bufnr) then
        local ok, lines = pcall(api.nvim_buf_get_lines, loc.bufnr, loc.lnum - 1, loc.lnum, true)
        line = ok and lines[1]
      else
        local fname = api.nvim_buf_get_name(loc.bufnr)
        local f = io.open(fname, "r")
        if f then
          local contents = f:read("*a")
          f:close()
          if contents then
            local lines = vim.split(contents, "\n")
            line = lines[loc.lnum]
          end
        end
      end
      local label =  M.format_bufname(loc.bufnr) .. ':' .. tostring(loc.lnum)
      if line then
        return label .. ': ' .. line
      else
        return label
      end
    end
  }
  local win = api.nvim_get_current_win()
  ui.select(locations, opts, function(loc)
    if loc then
      api.nvim_set_current_buf(loc.bufnr)
      api.nvim_win_set_cursor(win, { loc.lnum, loc.col })
      api.nvim_win_call(win, function()
        vim.cmd('normal! zvzz')
      end)
    end
  end)
end


--- Show tagstack. Open selected entry in current window and jump to its position
function M.tagstack()
  local function is_valid(x)
    return api.nvim_buf_is_valid(x.bufnr)
  end
  local items = vim.tbl_filter(is_valid, vim.fn.gettagstack().items)
  local opts = {
    prompt = 'Tagstack: ',
    format_item = function(loc)
      return M.format_bufname(loc.bufnr) .. ': ' .. loc.tagname
    end
  }
  local win = api.nvim_get_current_win()
  ui.select(items or {}, opts, function(loc)
    if loc then
      api.nvim_set_current_buf(loc.bufnr)
      api.nvim_win_set_cursor(win, { loc.from[2], loc.from[3] })
      api.nvim_win_call(win, function()
        vim.cmd('normal! zvzz')
      end)
    end
  end)
end


--- Show diagnostic and jump to the location if selected
---
---@param bufnr? integer 0 for current buffer; nil for all diagnostic
---@param opts? {lnum?: integer, severity?: DiagnosticSeverity} See vim.diagnostic.get
function M.diagnostic(bufnr, opts)
  local diagnostic = vim.diagnostic.get(bufnr, opts)
  local ui_opts = {
    prompt = 'Diagnostic: ',
    format_item = function(d)
      return d.message
    end
  }
  local win = api.nvim_get_current_win()
  ui.select(diagnostic, ui_opts, function(d)
    if d then
      api.nvim_set_current_buf(d.bufnr)
      api.nvim_win_set_cursor(win, { d.lnum + 1, d.col })
      api.nvim_win_call(win, function()
        vim.cmd('normal! zvzz')
      end)
    end
  end)
end


--- Show spelling suggestions for the word under the cursor.
--- Replaces the word if a suggestion is selected
function M.spellsuggest()
  local word = vim.fn.expand("<cword>")
  local suggestions = vim.fn.spellsuggest(word)
  local opts = {
    prompt = 'Change "' .. word .. '" to: ',
    format_item = function(x)
      return x
    end,
  }
  ui.select(suggestions, opts, function(choice)
    if choice then
      vim.cmd.normal({ "ciw" .. choice, bang = true })
      vim.cmd.stopinsert()
    end
  end)
end


--- Show helptags.
--- Opens the help and jumps to a tag on selection.
function M.helptags()
  local files = api.nvim_get_runtime_file("doc/tags", true)
  local tags = {}
  local delimiter = string.char(9)

  for _, file in ipairs(files) do
    for line in io.lines(file) do
      local fields = vim.split(line, delimiter, { plain = true })
      table.insert(tags, fields)
    end
  end

  local opts = {
    prompt = "Helptags: ",
    format_item = function(x)
      return x[1]
    end,
  }
  ui.select(tags, opts, function(choice)
    if choice then
      vim.cmd.help(choice[1])
    end
  end)
end


return M
