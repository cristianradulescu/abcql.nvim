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
