-- plugin/abcql.lua
-- This file is automatically loaded by Neovim when the plugin is installed
-- It defines user commands for the ABCQL plugin

-- Prevent loading the plugin twice
if vim.g.loaded_abcql then
  return
end
vim.g.loaded_abcql = true

-- Create user commands for ABCQL
-- These commands are always available once the plugin is loaded

--- Open the ABCQL UI
--- Creates a two-panel layout with query editor and results (tree hidden by default)
vim.api.nvim_create_user_command("AbcqlOpen", function()
  require("abcql.ui").open()
end, {
  desc = "Open ABCQL UI with query editor and results panel",
})

--- Close the ABCQL UI
--- Closes all windows and buffers associated with the ABCQL UI
vim.api.nvim_create_user_command("AbcqlClose", function()
  require("abcql.ui").close()
end, {
  desc = "Close ABCQL UI and cleanup all associated windows and buffers",
})

--- Toggle the visibility of the query results panel
--- If visible, hides it; if hidden, shows it in the correct position
vim.api.nvim_create_user_command("AbcqlToggleResults", function()
  require("abcql.ui").toggle_results()
end, {
  desc = "Toggle visibility of the ABCQL query results panel",
})

--- Toggle the visibility of the data source tree panel
--- If visible, hides it; if hidden, shows it in the correct position
vim.api.nvim_create_user_command("AbcqlToggleTree", function()
  require("abcql.ui").toggle_tree()
end, {
  desc = "Toggle visibility of the ABCQL data source tree panel",
})

--- Execute the statement under the cursor
vim.api.nvim_create_user_command("AbcqlExecute", function()
  require("abcql.db.query").execute_query_at_cursor()
end, {
  desc = "Execute the SQL statement under the cursor",
})

--- Execute the visual selection as one statement
vim.api.nvim_create_user_command("AbcqlExecuteSelection", function()
  require("abcql.db.query").execute_selection()
end, {
  desc = "Execute the visually selected SQL",
  range = true,
})

--- Execute every statement in the buffer, in order
vim.api.nvim_create_user_command("AbcqlExecuteBuffer", function()
  require("abcql.db.query").execute_buffer()
end, {
  desc = "Execute all SQL statements in the current buffer sequentially",
})

--- Cancel the running query
vim.api.nvim_create_user_command("AbcqlCancel", function()
  require("abcql.db.query").cancel()
end, {
  desc = "Cancel the running abcql query",
})

--- Attach a datasource to the current buffer (prompts when no name is given)
vim.api.nvim_create_user_command("AbcqlDatasource", function(opts)
  local name = opts.args ~= "" and opts.args or nil
  require("abcql.db").activate_datasource(vim.api.nvim_get_current_buf(), name)
end, {
  desc = "Attach a datasource to the current buffer",
  nargs = "?",
  complete = function()
    return require("abcql.db").get_datasource_names()
  end,
})

--- Pick a past query from history (re-run, insert or show its result)
vim.api.nvim_create_user_command("AbcqlHistory", function()
  require("abcql.history").pick({ bufnr = vim.api.nvim_get_current_buf() })
end, {
  desc = "Browse query history",
})

--- Export current query results to CSV format
--- Saves to current working directory with timestamp
vim.api.nvim_create_user_command("AbcqlExportCsv", function()
  require("abcql.export").export_current("csv")
end, {
  desc = "Export current query results to CSV file",
})

--- Export current query results to TSV format
--- Saves to current working directory with timestamp
vim.api.nvim_create_user_command("AbcqlExportTsv", function()
  require("abcql.export").export_current("tsv")
end, {
  desc = "Export current query results to TSV file",
})

--- Export current query results to JSON format
--- Saves to current working directory with timestamp (requires jq)
vim.api.nvim_create_user_command("AbcqlExportJson", function()
  require("abcql.export").export_current("json")
end, {
  desc = "Export current query results to JSON file",
})

--- Refresh LSP schema cache for the current buffer's datasource
--- Reloads databases, tables, and columns for SQL completion
vim.api.nvim_create_user_command("AbcqlRefreshSchema", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local Database = require("abcql.db")
  local datasource = Database.get_active_datasource(bufnr)

  if not datasource then
    vim.notify("No active datasource for this buffer", vim.log.levels.WARN)
    return
  end

  local LSP = require("abcql.lsp")
  LSP.refresh_schema(datasource.name, datasource.adapter, function(err)
    if err then
      vim.notify("Failed to refresh schema: " .. err, vim.log.levels.ERROR)
    end
  end)
end, {
  desc = "Refresh LSP schema cache for SQL completion",
})

--- Initialize a local .abcql.lua config file in the current working directory
vim.api.nvim_create_user_command("AbcqlInitConfig", function(opts)
  local loader = require("abcql.config.loader")
  local path, err

  if opts.args == "user" then
    path = loader.USER_DATASOURCES_PATH
    local success
    success, err = loader.init_user_config()
    if success then
      vim.notify("Created user config at: " .. path, vim.log.levels.INFO)
      vim.cmd.edit(path)
    end
  else
    path = loader.get_local_config_path()
    local success
    success, err = loader.init_local_config()
    if success then
      vim.notify("Created local config at: " .. path, vim.log.levels.INFO)
      vim.cmd.edit(path)
    end
  end

  if err then
    vim.notify(err, vim.log.levels.WARN)
  end
end, {
  desc = "Initialize abcql config file (.abcql.lua)",
  nargs = "?",
  complete = function()
    return { "local", "user" }
  end,
})

--- List all configured datasources with their source
vim.api.nvim_create_user_command("AbcqlListDatasources", function()
  local config = require("abcql.config")
  local loaded = config.get_loaded_datasources()

  if vim.tbl_isempty(loaded) then
    vim.notify("No datasources configured", vim.log.levels.INFO)
    return
  end

  local lines = { "Configured datasources:" }
  local names = vim.tbl_keys(loaded)
  table.sort(names)

  for _, name in ipairs(names) do
    local ds = loaded[name]
    local source_info = ds.source
    if ds.source_path then
      source_info = source_info .. " (" .. ds.source_path .. ")"
    end
    -- Mask password in DSN for display
    local display_dsn = ds.dsn:gsub("(://[^:]+:)[^@]+(@)", "%1****%2")
    table.insert(lines, string.format("  %s: %s [%s]", name, display_dsn, source_info))
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, {
  desc = "List all configured datasources",
})

--- Reload datasources from config files
vim.api.nvim_create_user_command("AbcqlReloadDatasources", function()
  require("abcql.config").reload_datasources()
end, {
  desc = "Reload datasources from config files",
})

local function display_history_entry(entry)
  local History = require("abcql.history")
  local UI = require("abcql.ui")
  local pos, total = History.get_position()
  local display_opts = {
    query = entry.query,
    history_position = string.format("history %d/%d", pos, total),
    datasource = { name = entry.datasource, adapter = { config = { database = entry.database } } },
  }
  UI.display(entry.error or entry.result, nil, display_opts)
end

--- Navigate to previous query in history
vim.api.nvim_create_user_command("AbcqlHistoryBack", function()
  local entry = require("abcql.history").go_back()
  if entry then
    display_history_entry(entry)
  end
end, {
  desc = "Navigate to previous query in history",
})

--- Navigate to next query in history (toward latest)
vim.api.nvim_create_user_command("AbcqlHistoryForward", function()
  local UI = require("abcql.ui")
  local entry, is_latest = require("abcql.history").go_forward()

  if is_latest then
    local results = UI.get_current_results()
    if results then
      UI.display(results)
    end
  elseif entry then
    display_history_entry(entry)
  end
end, {
  desc = "Navigate to next query in history",
})

--- Clear all query history
vim.api.nvim_create_user_command("AbcqlHistoryClear", function()
  local History = require("abcql.history")
  local deleted = History.clear()
  vim.notify(string.format("Cleared %d history entries", deleted), vim.log.levels.INFO)
end, {
  desc = "Clear all query history",
})

--- Show query history info
vim.api.nvim_create_user_command("AbcqlHistoryInfo", function()
  local History = require("abcql.history")
  local count = History.count()
  local pos, total = History.get_position()

  if count == 0 then
    vim.notify("No query history", vim.log.levels.INFO)
  else
    local status = pos == 0 and "viewing latest" or string.format("viewing %d/%d", pos, total)
    vim.notify(string.format("Query history: %d entries (%s)", count, status), vim.log.levels.INFO)
  end
end, {
  desc = "Show query history information",
})
