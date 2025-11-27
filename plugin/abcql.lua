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
--- Creates a three-panel layout with query editor, results panel, and data source tree
vim.api.nvim_create_user_command("AbcqlOpen", function()
  require("abcql.ui").open()
end, {
  desc = "Open ABCQL UI with query editor, results panel, and data source tree",
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
