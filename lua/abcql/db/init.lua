local ConnectionRegistry = require("abcql.db.connection.registry")
local LSP = require("abcql.lsp")

---@class abcql.Database
local Database = {
  --- @type abcql.db.connection.Registry
  connectionRegistry = nil,
  --- @type table<number, Datasource> Maps buffer numbers to active data sources
  buffer_datasources = {},
  --- @type string|nil Name of the datasource picked most recently (used for auto-attach)
  last_datasource_name = nil,
  --- @type string|nil Project/user/setup default datasource name
  default_datasource_name = nil,
}

Database.connectionRegistry = ConnectionRegistry.new()

--- Number of leading buffer lines scanned for a `-- abcql: <name>` comment
local MAGIC_COMMENT_LINES = 10

local AUGROUP = vim.api.nvim_create_augroup("abcql_datasource", { clear = true })

--- Setup the database module with configuration
--- @param config abcql.Config
function Database.setup(config)
  -- Reset registry to pick up changed DSN values on reload
  Database.connectionRegistry = ConnectionRegistry.new()

  -- Register built-in adapters
  local MySQLAdapter = require("abcql.db.adapter.mysql")
  Database.connectionRegistry:register_adapter("mysql", MySQLAdapter)
  -- @TODO: Register other adapters like PostgreSQL, SQLite, etc.

  -- Register data sources from config
  for name, ds_config in pairs(config.datasources or {}) do
    local is_table = type(ds_config) == "table"
    local dsn = is_table and ds_config.dsn or ds_config
    local proxy = is_table and ds_config.proxy or nil
    local secret = is_table and ds_config.secret or nil
    local opts = is_table
        and {
          readonly = ds_config.readonly,
          confirm = ds_config.confirm,
          highlight = ds_config.highlight,
        }
      or nil
    local _, err = Database.connectionRegistry:register_datasource(name, dsn, proxy, secret, opts)
    if err then
      vim.notify(string.format("abcql: datasource '%s': %s", name, err), vim.log.levels.ERROR)
    end
  end

  Database.default_datasource_name = config.default

  -- Re-point already attached buffers at the fresh registry entries
  for bufnr, datasource in pairs(Database.buffer_datasources) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      Database.buffer_datasources[bufnr] = Database.connectionRegistry:get_datasource(datasource.name) or nil
    else
      Database.buffer_datasources[bufnr] = nil
    end
  end
end

--- Sorted list of configured datasource names
--- @return string[]
function Database.get_datasource_names()
  local names = vim.tbl_keys(Database.connectionRegistry:get_all_datasources())
  table.sort(names)
  return names
end

--- Build the winbar text for a buffer's datasource
--- @param datasource Datasource|nil
--- @return string
function Database.winbar_text(datasource)
  if not datasource then
    return "%#AbcqlWinbarLabel# abcql %* no datasource"
  end

  local group = datasource.highlight or "AbcqlDatasource"
  local text = string.format("%%#AbcqlWinbarLabel# abcql %%*%%#%s# %s %%*", group, datasource.name:gsub("%%", "%%%%"))
  local db = datasource.adapter and datasource.adapter.config and datasource.adapter.config.database
  if db and db ~= "" then
    text = text .. " " .. db:gsub("%%", "%%%%")
  end
  if datasource.readonly then
    text = text .. " %#AbcqlReadonly#[readonly]%*"
  end
  return text
end

--- Apply the datasource winbar to every window showing the buffer
--- @param bufnr number
local function apply_winbar(bufnr)
  local datasource = Database.buffer_datasources[bufnr]
  local text = Database.winbar_text(datasource)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].winbar = text
  end
end

--- Detect a `-- abcql: <name>` (or `-- abcql: datasource=<name>`) comment in
--- the first lines of a buffer.
--- @param bufnr number
--- @return string|nil datasource_name
function Database.detect_datasource_comment(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, MAGIC_COMMENT_LINES, false)
  for _, line in ipairs(lines) do
    local name = line:match("^%s*%-%-%s*abcql%s*:%s*datasource%s*=%s*([%w_%-%.]+)")
      or line:match("^%s*%-%-%s*abcql%s*:%s*([%w_%-%.]+)")
    if name then
      return name
    end
  end
  return nil
end

--- Attach a datasource to a buffer by name (no prompt), update the winbar and start the LSP.
--- @param bufnr number
--- @param datasource_name string
--- @param callback? fun(datasource: Datasource|nil, err: string|nil)
function Database.attach_datasource(bufnr, datasource_name, callback)
  local datasource = Database.connectionRegistry:get_datasource(datasource_name)
  if not datasource then
    local err = "Unknown datasource: " .. tostring(datasource_name)
    if callback then
      callback(nil, err)
    end
    return
  end

  Database.buffer_datasources[bufnr] = datasource
  Database.last_datasource_name = datasource_name

  require("abcql.ui.highlights").setup()
  apply_winbar(bufnr)
  vim.api.nvim_exec_autocmds("User", { pattern = "AbcqlDatasourceAttached", modeline = false })

  -- Keep the winbar when the buffer is shown in a new window, and drop the
  -- mapping when the buffer goes away.
  vim.api.nvim_clear_autocmds({ group = AUGROUP, buffer = bufnr })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = AUGROUP,
    buffer = bufnr,
    callback = function()
      apply_winbar(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = AUGROUP,
    buffer = bufnr,
    once = true,
    callback = function()
      Database.buffer_datasources[bufnr] = nil
    end,
  })

  -- Start LSP for this buffer
  LSP.start(bufnr, datasource, function(lsp_err)
    if lsp_err then
      vim.notify("abcql: failed to start completion: " .. lsp_err, vim.log.levels.ERROR)
    end
  end)

  if callback then
    callback(datasource, nil)
  end
end

--- Activate a data source for a buffer. With a name, attaches directly;
--- otherwise prompts with vim.ui.select.
--- @param bufnr number
--- @param datasource_name? string
--- @param callback? fun(datasource: Datasource|nil, err: string|nil)
function Database.activate_datasource(bufnr, datasource_name, callback)
  if datasource_name then
    Database.attach_datasource(bufnr, datasource_name, callback)
    return
  end

  local names = Database.get_datasource_names()
  if #names == 0 then
    vim.notify("abcql: no datasources configured (see :AbcqlConfigInit)", vim.log.levels.WARN)
    if callback then
      callback(nil, "No datasources configured")
    end
    return
  end

  local current = Database.buffer_datasources[bufnr]
  vim.ui.select(names, {
    prompt = "Select datasource:",
    format_item = function(name)
      local ds = Database.connectionRegistry:get_datasource(name)
      local marks = {}
      if current and current.name == name then
        table.insert(marks, "current")
      end
      if ds and ds.readonly then
        table.insert(marks, "readonly")
      end
      if #marks > 0 then
        return name .. "  (" .. table.concat(marks, ", ") .. ")"
      end
      return name
    end,
  }, function(choice)
    if not choice then
      if callback then
        callback(nil, "cancelled")
      end
      return
    end
    Database.attach_datasource(bufnr, choice, function(datasource, err)
      if err then
        vim.notify("abcql: " .. err, vim.log.levels.ERROR)
      end
      if callback then
        callback(datasource, err)
      end
    end)
  end)
end

--- Get the active data source for a buffer
--- @param bufnr number
--- @return Datasource|nil
function Database.get_active_datasource(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return Database.buffer_datasources[bufnr]
end

--- Resolve the datasource for a buffer without prompting:
--- explicit attachment > `-- abcql: <name>` comment > configured default >
--- last used (when query.auto_attach is on).
--- @param bufnr number
--- @return string|nil name
--- @return string|nil reason Human-readable origin of the pick
function Database.resolve_datasource_name(bufnr)
  local attached = Database.buffer_datasources[bufnr]
  if attached then
    return attached.name, "attached"
  end

  local registry = Database.connectionRegistry
  local from_comment = Database.detect_datasource_comment(bufnr)
  if from_comment then
    if registry:get_datasource(from_comment) then
      return from_comment, "file comment"
    end
    vim.notify(
      string.format("abcql: datasource '%s' from file comment is not configured", from_comment),
      vim.log.levels.WARN
    )
  end

  local default = Database.default_datasource_name
  if default and registry:get_datasource(default) then
    return default, "default"
  end

  local ok, config = pcall(require, "abcql.config")
  local auto_attach = not ok or config.query == nil or config.query.auto_attach ~= false
  local last = Database.last_datasource_name
  if auto_attach and last and registry:get_datasource(last) then
    return last, "last used"
  end

  return nil, nil
end

--- Ensure a buffer has a datasource, auto-attaching or prompting as needed.
--- @param bufnr number
--- @param callback fun(datasource: Datasource|nil)
function Database.ensure_datasource(bufnr, callback)
  local attached = Database.buffer_datasources[bufnr]
  if attached then
    callback(attached)
    return
  end

  local name, reason = Database.resolve_datasource_name(bufnr)
  if name then
    Database.attach_datasource(bufnr, name, function(datasource, err)
      if err then
        vim.notify("abcql: " .. err, vim.log.levels.ERROR)
        callback(nil)
        return
      end
      vim.notify(string.format("abcql: using datasource '%s' (%s)", name, reason), vim.log.levels.INFO)
      callback(datasource)
    end)
    return
  end

  Database.activate_datasource(bufnr, nil, function(datasource)
    callback(datasource)
  end)
end

return Database
