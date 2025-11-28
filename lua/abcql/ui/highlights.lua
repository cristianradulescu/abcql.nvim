--- Highlight groups for abcql results pane
local M = {}

--- Namespace for abcql extmarks
M.ns = vim.api.nvim_create_namespace("abcql_results")

--- Define highlight groups with sensible defaults
--- These link to existing highlight groups so they adapt to the user's colorscheme
function M.setup()
  -- Table structure
  vim.api.nvim_set_hl(0, "AbcqlBorder", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AbcqlHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "AbcqlHeaderSeparator", { link = "Comment", default = true })

  -- Cell values
  vim.api.nvim_set_hl(0, "AbcqlNull", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AbcqlNumber", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "AbcqlString", { link = "String", default = true })
  vim.api.nvim_set_hl(0, "AbcqlBoolean", { link = "Boolean", default = true })

  -- Alternating rows (subtle background difference)
  vim.api.nvim_set_hl(0, "AbcqlRowEven", { default = true })
  vim.api.nvim_set_hl(0, "AbcqlRowOdd", { link = "CursorLine", default = true })

  -- Footer/metadata
  vim.api.nvim_set_hl(0, "AbcqlFooter", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AbcqlRowCount", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "AbcqlDuration", { link = "String", default = true })

  -- Status indicators
  vim.api.nvim_set_hl(0, "AbcqlSuccess", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "AbcqlError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "AbcqlWarning", { link = "DiagnosticWarn", default = true })
end

--- Check if a string looks like a number
--- @param str string
--- @return boolean
local function is_number(str)
  if str == nil or str == "" or str == "NULL" then
    return false
  end
  -- Match integers, decimals, negative numbers, scientific notation
  return str:match("^%-?%d+%.?%d*$") ~= nil or str:match("^%-?%d+%.%d+[eE][+-]?%d+$") ~= nil
end

--- Check if a string looks like a boolean
--- @param str string
--- @return boolean
local function is_boolean(str)
  if str == nil then
    return false
  end
  local lower = str:lower()
  return lower == "true" or lower == "false" or lower == "1" or lower == "0"
end

--- Apply highlights to the results buffer
--- @param buf number Buffer ID
--- @param results table Query results with headers and rows
--- @param line_offset number Starting line number (0-indexed)
--- @param widths table Column widths array
function M.apply_highlights(buf, results, line_offset, widths)
  -- Clear existing extmarks
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  local headers = results.headers or {}
  local rows = results.rows or {}

  if #headers == 0 then
    return
  end

  -- Get the actual line content to calculate byte positions correctly
  -- Unicode characters like │ are 3 bytes each
  local lines = vim.api.nvim_buf_get_lines(buf, line_offset, line_offset + 4 + #rows, false)

  -- Line 0: Top border
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlBorder", line_offset, 0, -1)

  -- Line 1: Header row - highlight entire line as border, then overlay header text
  local header_line = line_offset + 1
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlBorder", header_line, 0, -1)

  -- Calculate byte positions by finding the vertical bar positions in the actual line
  local header_line_content = lines[2] or ""
  local col_byte_positions = {}

  -- Find each │ character and the content between them
  local byte_pos = 1
  local col_idx = 1
  while byte_pos <= #header_line_content do
    -- Check for start of │ (first byte is 0xE2 in UTF-8 for box drawing)
    if header_line_content:sub(byte_pos, byte_pos + 2) == "│" then
      -- Skip the │ and the space after it
      byte_pos = byte_pos + 3 + 1 -- 3 bytes for │, 1 for space
      if col_idx <= #widths then
        col_byte_positions[col_idx] = { start = byte_pos, width = widths[col_idx] }
        col_idx = col_idx + 1
      end
      -- Skip past the column content
      byte_pos = byte_pos + widths[col_idx - 1]
    else
      byte_pos = byte_pos + 1
    end
  end

  -- Apply header highlights using calculated positions
  for i, col_info in ipairs(col_byte_positions) do
    if headers[i] then
      local start_byte = col_info.start - 1 -- 0-indexed for nvim API
      local header_text = tostring(headers[i])
      local end_byte = start_byte + #header_text
      vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlHeader", header_line, start_byte, end_byte)
    end
  end

  -- Line 2: Header separator
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlHeaderSeparator", line_offset + 2, 0, -1)

  -- Data rows
  for row_idx, row in ipairs(rows) do
    local line_num = line_offset + 2 + row_idx -- +2 for top border and header
    local row_hl = (row_idx % 2 == 0) and "AbcqlRowEven" or "AbcqlRowOdd"

    -- Apply alternating row background to entire line
    vim.api.nvim_buf_add_highlight(buf, M.ns, row_hl, line_num, 0, -1)

    -- Highlight individual cells based on content
    for i, col_info in ipairs(col_byte_positions) do
      local cell = row[i]
      local cell_str = cell == nil and "NULL" or tostring(cell)
      local start_byte = col_info.start - 1 -- 0-indexed

      -- Calculate actual byte length of the cell content (might be truncated)
      local display_width = vim.fn.strdisplaywidth(cell_str)
      local actual_str = cell_str
      if display_width > col_info.width then
        -- Content was truncated, need to find truncated version
        actual_str = require("abcql.ui.format").truncate(cell_str, col_info.width)
      end
      local end_byte = start_byte + #actual_str

      local cell_hl
      if cell == nil or cell_str == "NULL" then
        cell_hl = "AbcqlNull"
      elseif is_boolean(cell_str) then
        cell_hl = "AbcqlBoolean"
      elseif is_number(cell_str) then
        cell_hl = "AbcqlNumber"
      else
        cell_hl = "AbcqlString"
      end

      vim.api.nvim_buf_add_highlight(buf, M.ns, cell_hl, line_num, start_byte, end_byte)
    end
  end

  -- Bottom border line
  local bottom_line = line_offset + 3 + #rows
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlBorder", bottom_line, 0, -1)
end

--- Apply highlights for error display
--- @param buf number Buffer ID
--- @param start_line number Starting line (0-indexed)
--- @param end_line number Ending line (0-indexed, exclusive)
function M.apply_error_highlights(buf, start_line, end_line)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  for line = start_line, end_line - 1 do
    vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlError", line, 0, -1)
  end
end

--- Apply highlights for write query results (INSERT, UPDATE, DELETE)
--- @param buf number Buffer ID
--- @param start_line number Starting line (0-indexed)
--- @param end_line number Ending line (0-indexed, exclusive)
function M.apply_write_highlights(buf, start_line, end_line)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  -- First non-empty line is the success message
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlSuccess", start_line + 1, 0, -1)

  -- Rest is metadata
  for line = start_line + 2, end_line - 1 do
    vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlFooter", line, 0, -1)
  end
end

--- Apply highlights for footer (row count, duration)
--- @param buf number Buffer ID
--- @param line_num number Line number (0-indexed)
function M.apply_footer_highlight(buf, line_num)
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AbcqlFooter", line_num, 0, -1)
end

return M
