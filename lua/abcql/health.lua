local M = {}

local health = vim.health

local function is_linux()
  local uname = vim.uv.os_uname()
  return uname and uname.sysname == "Linux"
end

local function check_core_dependencies()
  health.start("Core dependencies")

  if vim.fn.executable("mysql") == 1 then
    health.ok("mysql CLI is available")
  else
    health.error("mysql CLI is not available", {
      "Install MySQL client tools so abcql can execute queries.",
      "Debian/Ubuntu: apt install mysql-client",
      "Fedora: dnf install mysql",
      "Arch: pacman -S mysql-clients",
    })
  end

  if vim.fn.executable("jq") == 1 then
    health.ok("jq is available (JSON export enabled)")
  else
    health.warn("jq is not available (JSON export disabled)", {
      "Install jq to use :AbcqlExportJson.",
    })
  end
end

local function load_datasources_for_health()
  local ok_loader, loader = pcall(require, "abcql.config.loader")
  if not ok_loader then
    health.error("Failed to load abcql config loader: " .. tostring(loader))
    return {}
  end

  local loaded = {}

  local ok_config, config = pcall(require, "abcql.config")
  if ok_config and config.get_loaded_datasources then
    loaded = config.get_loaded_datasources()
  end

  if vim.tbl_isempty(loaded) then
    local ok, result = pcall(loader.load_all_datasources, nil)
    if ok and type(result) == "table" then
      loaded = result
    else
      health.error("Failed to load datasource config", {
        tostring(result),
      })
      loaded = {}
    end
  end

  return loaded
end

local function validate_secret_ref(name, secret)
  if type(secret) ~= "table" then
    health.error(string.format("%s: secret config must be a table", name))
    return false
  end

  local provider = secret.provider or "secret-tool"
  if provider ~= "secret-tool" then
    health.error(string.format("%s: unsupported secret provider '%s'", name, tostring(provider)), {
      "Linux support currently uses provider = 'secret-tool'.",
    })
    return false
  end

  if type(secret.service) ~= "string" or secret.service == "" then
    health.error(string.format("%s: secret.service is required", name))
    return false
  end

  if type(secret.account) ~= "string" or secret.account == "" then
    health.error(string.format("%s: secret.account is required", name))
    return false
  end

  return true
end

local function check_datasource_configs(datasources)
  health.start("Datasource configuration")

  if vim.tbl_isempty(datasources) then
    health.warn("No datasources configured", {
      "Create .abcql.lua in your project or ~/.config/nvim/abcql/datasources.lua",
      "Use :AbcqlInitConfig to scaffold a config file.",
    })
    return {}
  end

  local names = vim.tbl_keys(datasources)
  table.sort(names)

  local secret_backed = {}

  for _, name in ipairs(names) do
    local ds = datasources[name]
    local has_dsn = type(ds) == "table" and type(ds.dsn) == "string" and ds.dsn ~= ""
    if not has_dsn then
      health.error(string.format("%s: missing or invalid dsn", name))
    else
      local source = ds.source or "unknown"
      health.ok(string.format("%s: datasource loaded (%s)", name, source))
    end

    if type(ds) == "table" and ds.secret ~= nil then
      table.insert(secret_backed, { name = name, ref = ds.secret })
    end
  end

  return secret_backed
end

local function check_secret_datasources(secret_backed)
  health.start("Linux keyring secrets")

  if #secret_backed == 0 then
    health.info("No keyring-backed datasources configured")
    return
  end

  if not is_linux() then
    health.error("Keyring-backed datasource secrets currently support Linux only")
    return
  end

  local ok_linux, linux_secret = pcall(require, "abcql.secret.linux")
  if not ok_linux then
    health.error("Failed to load Linux secret backend", { tostring(linux_secret) })
    return
  end

  if not linux_secret.is_available() then
    health.error("secret-tool is not available", {
      "Install libsecret-tools to use keyring-backed datasource secrets.",
      "Debian/Ubuntu: apt install libsecret-tools",
      "Fedora: dnf install libsecret",
      "Arch: pacman -S libsecret",
    })
    return
  end

  health.ok("secret-tool is available")

  local ok_secret, secret = pcall(require, "abcql.secret")
  if not ok_secret then
    health.error("Failed to load secret resolution module", { tostring(secret) })
    return
  end

  for _, item in ipairs(secret_backed) do
    if validate_secret_ref(item.name, item.ref) then
      local value, err = secret.lookup(item.ref)
      if value then
        health.ok(string.format("%s: keyring secret lookup succeeded", item.name))
      else
        health.warn(string.format("%s: keyring secret lookup failed", item.name), {
          tostring(err),
          string.format(
            "Store it with: secret-tool store --label='abcql %s password' service %s account %s",
            item.name,
            item.ref.service,
            item.ref.account
          ),
        })
      end
    end
  end
end

function M.check()
  check_core_dependencies()
  local datasources = load_datasources_for_health()
  local secret_backed = check_datasource_configs(datasources)
  check_secret_datasources(secret_backed)
end

return M
