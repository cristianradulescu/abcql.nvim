-- ftplugin/sql.lua
-- This file is automatically loaded for buffers with filetype=sql

-- Set buffer-local options
vim.opt_local.commentstring = "-- %s"

-- Update winbar to show abcql is active, connected data source and database
vim.wo.winbar = "[abcql.nvim] | Data source: "
  .. (require("abcql.db").get_active_datasource(vim.api.nvim_get_current_buf()) or "`Not selected`")
