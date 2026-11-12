--- Interactive add/update of datasources in config files (.abcql.lua or the
--- user datasources file). Prompts go through vim.ui.input/select so they work
--- with whatever picker the user has installed -- except passwords, which are
--- read with inputsecret() (M.read_secret): not echoed, and not recorded in the
--- input history that ShaDa writes to disk.
---@class abcql.config.Editor
local M = {}

local loader = require("abcql.config.loader")
local Dsn = require("abcql.db.connection.dsn")

--- Prompt for a line of text; nil (cancelled) aborts the whole flow
--- @param prompt string
--- @param default string
--- @param callback fun(value: string, raw: string) `value` is trimmed, `raw` is what was typed
local function ask(prompt, default, callback)
  vim.ui.input({ prompt = prompt, default = default }, function(value)
    if value == nil then
      vim.notify("abcql: cancelled", vim.log.levels.INFO)
      return
    end
    callback(vim.trim(value), value)
  end)
end

--- Read a password without echoing it and without adding it to the input
--- history. Replaced in specs.
--- @param prompt string
--- @return string|nil password nil when cancelled (<C-c>); <Esc> gives ""
function M.read_secret(prompt)
  local ok, value = pcall(vim.fn.inputsecret, prompt)
  if not ok then
    return nil
  end
  return value
end

--- Prompt for a password (see M.read_secret); cancelling aborts the flow.
--- The value is not trimmed: spaces may be part of a password.
--- @param prompt string
--- @param callback fun(password: string)
local function ask_secret(prompt, callback)
  local value = M.read_secret(prompt)
  if value == nil then
    vim.notify("abcql: cancelled", vim.log.levels.INFO)
    return
  end
  callback(value)
end

--- Whether a DSN as typed carries a password of its own
--- @param dsn string
--- @return boolean
local function has_inline_password(dsn)
  local parts = Dsn.split_userinfo(dsn)
  return parts ~= nil and parts.password ~= nil and parts.password ~= ""
end

--- Remove a typed value from the "input" history. vim.ui.input's default
--- implementation (vim.fn.input) records it there and ShaDa saves that history on
--- exit, so a DSN typed with its password must not stay in it.
--- @param value string
function M.forget_input(value)
  if type(value) ~= "string" or value == "" then
    return
  end
  local last = vim.fn.histnr("input")
  for i = last, math.max(1, last - vim.o.history), -1 do
    if vim.fn.histget("input", i) == value then
      vim.fn.histdel("input", i)
    end
  end
end

--- Prompt for a DSN; when the typed DSN has an inline password it is dropped
--- from the input history before `callback` runs.
--- @param prompt string
--- @param default string
--- @param callback fun(dsn: string)
local function ask_dsn(prompt, default, callback)
  ask(prompt, default, function(dsn, raw)
    if has_inline_password(dsn) then
      M.forget_input(raw)
      M.forget_input(dsn)
    end
    callback(dsn)
  end)
end

--- Prompt for a choice; nil (cancelled) aborts the whole flow
--- @param prompt string
--- @param items string[]
--- @param callback fun(choice: string)
local function choose(prompt, items, callback)
  vim.ui.select(items, { prompt = prompt }, function(choice)
    if choice == nil then
      vim.notify("abcql: cancelled", vim.log.levels.INFO)
      return
    end
    callback(choice)
  end)
end

--- Reload datasources after a config file changed, tolerating a missing config setup
local function reload()
  require("abcql.config").reload_datasources()
end

--- Offer to attach a datasource to the current buffer when it is a SQL buffer
--- @param name string
local function offer_attach(name)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "sql" then
    return
  end
  local current = require("abcql.db").get_active_datasource(bufnr)
  if current and current.name == name then
    return
  end
  choose("Attach '" .. name .. "' to this buffer?", { "Yes", "No" }, function(answer)
    if answer == "Yes" then
      require("abcql.db").attach_datasource(bufnr, name)
    end
  end)
end

--- Store a password in the keyring and point the entry's secret at it
--- @param name string
--- @param entry table
--- @param password string
--- @param callback fun(ok: boolean)
local function store_in_keyring(name, entry, password, callback)
  local Secret = require("abcql.secret")
  local ref = entry.secret or { service = "abcql", account = name .. "-db-password" }
  local ok, err = Secret.store(ref, password)
  if not ok then
    vim.notify("abcql: failed to store the password in the keyring: " .. tostring(err), vim.log.levels.ERROR)
    callback(false)
    return
  end
  entry.dsn = loader.strip_dsn_password(entry.dsn)
  entry.secret = ref
  vim.notify(
    string.format("abcql: password stored in the keyring (service=%s, account=%s)", ref.service, ref.account),
    vim.log.levels.INFO
  )
  callback(true)
end

--- Password currently embedded in the entry's DSN, if any
--- @param entry table
--- @return string|nil
local function dsn_password(entry)
  local parsed = Dsn.parse_dsn(loader.expand_env_vars(entry.dsn))
  local password = parsed and parsed.password
  if password == "" then
    return nil
  end
  return password
end

--- Whether the entry's DSN names a local database file (no password, no proxy)
--- @param entry table
--- @return boolean
local function is_file_dsn(entry)
  local scheme = (entry.dsn or ""):match("^(%w+)://")
  return scheme ~= nil and Dsn.FILE_SCHEMES[scheme:lower()] == true
end

--- Labels of the add flow's password step
local PASSWORD_NONE = "No password"
local PASSWORD_KEYRING = "Enter it, stored in the keyring (secret-tool)"
local PASSWORD_FILE = "Enter it, saved in the DSN in the config file"

--- Ask for the password and where it should live (keyring or DSN). Calls back
--- once the entry reflects the choice. The password itself is read with
--- inputsecret; a password typed inline in the DSN can be moved to the keyring.
--- @param name string
--- @param entry table
--- @param callback fun()
local function ask_password_storage(name, entry, callback)
  if is_file_dsn(entry) then
    callback()
    return
  end
  local keyring = require("abcql.secret").is_available()

  local in_dsn = dsn_password(entry)
  if in_dsn then
    if not keyring then
      callback()
      return
    end
    local keep, move = "Keep it in the DSN", "Move it to the keyring (secret-tool)"
    choose("Password for '" .. name .. "':", { keep, move }, function(choice)
      if choice == keep then
        callback()
        return
      end
      store_in_keyring(name, entry, in_dsn, function()
        callback()
      end)
    end)
    return
  end

  local items = { PASSWORD_NONE }
  if keyring then
    table.insert(items, PASSWORD_KEYRING)
  end
  table.insert(items, PASSWORD_FILE)
  choose("Password for '" .. name .. "':", items, function(choice)
    if choice == PASSWORD_NONE then
      callback()
      return
    end
    local prompt = choice == PASSWORD_KEYRING and "Password (stored in the keyring only): " or "Password: "
    ask_secret(prompt, function(password)
      if password == "" then
        vim.notify("abcql: empty password, none set", vim.log.levels.WARN)
        callback()
        return
      end
      if choice == PASSWORD_KEYRING then
        store_in_keyring(name, entry, password, function()
          callback()
        end)
        return
      end
      local with_password = loader.set_dsn_password(entry.dsn, password)
      if with_password == entry.dsn then
        vim.notify("abcql: the DSN names no user, so no password was set", vim.log.levels.WARN)
      end
      entry.dsn = with_password
      callback()
    end)
  end)
end

--- Apply one of the "Options" choices to an entry (add flow)
--- @param name string
--- @param entry table
--- @param callback fun()
local function ask_options(name, entry, callback)
  local options = { "None", "Readonly", "Always confirm" }
  if not is_file_dsn(entry) then
    table.insert(options, "SOCKS proxy")
  end
  choose("Options for '" .. name .. "':", options, function(opt)
    if opt == "Readonly" then
      entry.readonly = true
      entry.highlight = "DiagnosticWarn"
    elseif opt == "Always confirm" then
      entry.confirm = "always"
      entry.highlight = "DiagnosticError"
    end
    if opt == "SOCKS proxy" then
      ask("Proxy URL: ", "socks5://127.0.0.1:1080", function(proxy)
        if proxy ~= "" then
          entry.proxy = proxy
        end
        callback()
      end)
    else
      callback()
    end
  end)
end

--- Config file path for a scope
--- @param scope "local"|"user"
--- @return string
local function scope_path(scope)
  return scope == "user" and loader.USER_DATASOURCES_PATH or loader.get_local_config_path()
end

--- Interactively add a datasource: name, DSN, password storage, options; then
--- write it, reload, and offer to attach it to the current buffer.
--- @param scope? "local"|"user" Target config file (prompted when nil)
function M.add(scope)
  local function collect(target)
    ask("Datasource name: ", "", function(name)
      if name == "" then
        vim.notify("abcql: a name is required", vim.log.levels.WARN)
        return
      end
      -- sqlite:///path/to/file.db for a SQLite database. No password in the
      -- default: it is asked for next, without echo or history.
      ask_dsn("DSN (password asked next): ", "mysql://user@localhost:3306/database", function(dsn)
        if dsn == "" then
          vim.notify("abcql: a DSN is required", vim.log.levels.WARN)
          return
        end
        local entry = { dsn = dsn }
        ask_password_storage(name, entry, function()
          ask_options(name, entry, function()
            local path = scope_path(target)
            local ok, err = loader.add_datasource_to_file(path, name, entry)
            if not ok then
              vim.notify("abcql: " .. err, vim.log.levels.ERROR)
              return
            end
            local hint = target == "local" and " (add it to .gitignore if it holds credentials)" or ""
            vim.notify(string.format("abcql: added '%s' to %s%s", name, path, hint), vim.log.levels.INFO)
            reload()
            offer_attach(name)
          end)
        end)
      end)
    end)
  end

  if scope == "local" or scope == "user" then
    collect(scope)
    return
  end
  choose("Save the datasource where?", {
    "local (" .. loader.get_local_config_path() .. ")",
    "user (" .. loader.USER_DATASOURCES_PATH .. ")",
  }, function(choice)
    collect(choice:match("^user") and "user" or "local")
  end)
end

--- Datasources that can be edited (they come from a config file), sorted by name
--- @return { name: string, path: string }[]
function M.editable_datasources()
  local loaded = require("abcql.config").get_loaded_datasources()
  local items = {}
  for name, data in pairs(loaded) do
    if data.source_path then
      table.insert(items, { name = name, path = data.source_path })
    end
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return items
end

--- Read the raw (unexpanded) entry of a datasource from its config file
--- @param path string
--- @param name string
--- @return table|nil entry
--- @return string|nil err
function M.read_entry(path, name)
  local config, err = loader.load_config_file(path)
  if not config then
    return nil, err or ("Could not read " .. path)
  end
  local raw = config.datasources and config.datasources[name]
  if raw == nil then
    return nil, string.format("Datasource '%s' not found in %s", name, path)
  end
  if type(raw) == "string" then
    return { dsn = raw }, nil
  end
  return {
    dsn = raw.dsn,
    proxy = raw.proxy,
    secret = raw.secret,
    readonly = raw.readonly == true or nil,
    confirm = raw.confirm,
    highlight = raw.highlight,
    auto_limit = raw.auto_limit,
    lint_dangerous = raw.lint_dangerous,
    session = raw.session,
    history_rows = raw.history_rows,
  },
    nil
end

--- One-line description of an entry for the update menu
--- @param entry table
--- @return string
local function describe(entry)
  local parts = { "dsn=" .. loader.strip_dsn_password(entry.dsn or "") }
  if entry.secret then
    table.insert(parts, "password=keyring")
  elseif dsn_password(entry) then
    table.insert(parts, "password=dsn")
  end
  if entry.readonly then
    table.insert(parts, "readonly")
  end
  if entry.confirm then
    table.insert(parts, "confirm=" .. entry.confirm)
  end
  if entry.proxy then
    table.insert(parts, "proxy=" .. Dsn.mask(entry.proxy))
  end
  return table.concat(parts, " ")
end

--- A DSN typed in the update flow (whose prompt is pre-filled without the
--- password) gets the old DSN's password back, unless it has one of its own or
--- names no user. The password is carried over as written (raw), so a `${VAR}`
--- reference stays a reference.
--- @param dsn string The DSN as typed
--- @param raw_password string|nil The old DSN's raw password
--- @return string
local function keep_password(dsn, raw_password)
  local parts = Dsn.split_userinfo(dsn)
  if not raw_password or not parts or parts.password or not parts.user or parts.user == "" then
    return dsn
  end
  return parts.prefix .. parts.user .. ":" .. raw_password .. "@" .. parts.rest
end

--- Menu loop for editing an entry; calls back with the final entry on Save
--- @param name string
--- @param entry table
--- @param on_save fun(entry: table)
local function edit_loop(name, entry, on_save)
  local function again()
    edit_loop(name, entry, on_save)
  end

  local file = is_file_dsn(entry)
  local items = { "Save", "DSN: " .. Dsn.mask(entry.dsn or "") }
  if not file then
    table.insert(items, "Password: " .. (entry.secret and "keyring" or (dsn_password(entry) and "in DSN" or "none")))
  end
  table.insert(items, "Readonly: " .. (entry.readonly and "on" or "off"))
  table.insert(items, "Confirm: " .. (entry.confirm or "default"))
  if not file then
    table.insert(items, "Proxy: " .. (entry.proxy and Dsn.mask(entry.proxy) or "none"))
  end

  choose("Update '" .. name .. "' (" .. describe(entry) .. "):", items, function(choice)
    local field = choice:match("^(%a+)")
    if field == "Save" then
      on_save(entry)
    elseif field == "DSN" then
      -- Pre-filled without the password, which is kept unless a new one is typed
      local old = Dsn.split_userinfo(entry.dsn or "")
      local raw_password = old and old.password ~= "" and old.password or nil
      local prompt = raw_password and "DSN (its password is kept; change it under Password): " or "DSN: "
      ask_dsn(prompt, loader.strip_dsn_password(entry.dsn or ""), function(dsn)
        if dsn ~= "" then
          entry.dsn = keep_password(dsn, raw_password)
        end
        again()
      end)
    elseif field == "Password" then
      local options = { "Set password in the DSN" }
      if require("abcql.secret").is_available() then
        table.insert(
          options,
          dsn_password(entry) and "Move DSN password to the keyring" or "Set password in the keyring"
        )
      end
      if entry.secret then
        table.insert(options, "Stop using the keyring (password back in the DSN)")
      elseif dsn_password(entry) then
        table.insert(options, "Remove the password from the DSN")
      end
      choose("Password for '" .. name .. "':", options, function(opt)
        if opt:match("^Set password in the DSN") or opt:match("^Stop using") then
          ask_secret("Password: ", function(password)
            if password ~= "" then
              entry.dsn = loader.set_dsn_password(entry.dsn, password)
            end
            entry.secret = nil
            again()
          end)
        elseif opt:match("^Remove") then
          entry.dsn = loader.strip_dsn_password(entry.dsn)
          again()
        elseif opt:match("^Move") then
          store_in_keyring(name, entry, dsn_password(entry), function()
            again()
          end)
        else
          ask_secret("Password (stored in the keyring only): ", function(password)
            if password == "" then
              again()
              return
            end
            store_in_keyring(name, entry, password, function()
              again()
            end)
          end)
        end
      end)
    elseif field == "Readonly" then
      entry.readonly = (not entry.readonly) or nil
      again()
    elseif field == "Confirm" then
      choose("Confirm policy:", { "default", "always", "writes", "never" }, function(policy)
        entry.confirm = policy ~= "default" and policy or nil
        again()
      end)
    elseif field == "Proxy" then
      ask("Proxy URL (empty to remove): ", entry.proxy or "socks5://127.0.0.1:1080", function(proxy)
        entry.proxy = proxy ~= "" and proxy or nil
        again()
      end)
    else
      again()
    end
  end)
end

--- Interactively update a datasource stored in a config file.
--- @param name? string Datasource name (prompted when nil)
function M.update(name)
  local items = M.editable_datasources()
  if #items == 0 then
    vim.notify("abcql: no datasources in config files to update (use :AbcqlDatasourceAdd)", vim.log.levels.WARN)
    return
  end

  local function edit(item)
    local entry, err = M.read_entry(item.path, item.name)
    if not entry then
      vim.notify("abcql: " .. err, vim.log.levels.ERROR)
      return
    end
    edit_loop(item.name, entry, function(final)
      local ok, write_err = loader.update_datasource_in_file(item.path, item.name, final)
      if not ok then
        vim.notify("abcql: " .. write_err, vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("abcql: updated '%s' in %s", item.name, item.path), vim.log.levels.INFO)
      reload()
      offer_attach(item.name)
    end)
  end

  if name then
    for _, item in ipairs(items) do
      if item.name == name then
        edit(item)
        return
      end
    end
    vim.notify(string.format("abcql: datasource '%s' is not defined in a config file", name), vim.log.levels.WARN)
    return
  end

  vim.ui.select(items, {
    prompt = "Update datasource:",
    format_item = function(item)
      return item.name .. "  (" .. item.path .. ")"
    end,
  }, function(item)
    if item then
      edit(item)
    end
  end)
end

return M
