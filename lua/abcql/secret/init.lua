local M = {}

--- Validate a secret reference
--- @param ref table
--- @return string|nil err
local function validate(ref)
  if type(ref) ~= "table" then
    return "invalid secret reference"
  end

  local provider = ref.provider or "secret-tool"
  if provider ~= "secret-tool" then
    return "unsupported secret provider: " .. tostring(provider)
  end

  if type(ref.service) ~= "string" or ref.service == "" then
    return "secret.service is required"
  end

  if type(ref.account) ~= "string" or ref.account == "" then
    return "secret.account is required"
  end

  return nil
end

--- Whether a secret backend is available on this machine
--- @return boolean
function M.is_available()
  return require("abcql.secret.linux").is_available()
end

function M.lookup(ref)
  local err = validate(ref)
  if err then
    return nil, err
  end

  return require("abcql.secret.linux").lookup(ref.service, ref.account)
end

--- Store a password under a secret reference
--- @param ref { service: string, account: string, provider?: string }
--- @param password string
--- @return boolean ok
--- @return string|nil err
function M.store(ref, password)
  local err = validate(ref)
  if err then
    return false, err
  end
  if type(password) ~= "string" or password == "" then
    return false, "password is empty"
  end

  return require("abcql.secret.linux").store(ref.service, ref.account, password)
end

return M
