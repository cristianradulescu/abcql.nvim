-- ftplugin/sql.lua
-- This file is automatically loaded for buffers with filetype=sql

-- Set buffer-local options
vim.opt_local.commentstring = "-- %s"

-- Update winbar to show abcql is active, connected data source and database
local db_ok, Database = pcall(require, "abcql.db")
if not db_ok then
  return
end

local ds = Database.get_active_datasource(vim.api.nvim_get_current_buf())
local ds_name = ds and ds.name or "`Not selected`"
vim.wo.winbar = "[abcql.nvim] | Data source: " .. ds_name
