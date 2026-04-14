local M = {}

function M.lookup(ref)
  if type(ref) ~= "table" then
    return nil, "invalid secret reference"
  end

  local provider = ref.provider or "secret-tool"
  if provider ~= "secret-tool" then
    return nil, "unsupported secret provider: " .. tostring(provider)
  end

  if type(ref.service) ~= "string" or ref.service == "" then
    return nil, "secret.service is required"
  end

  if type(ref.account) ~= "string" or ref.account == "" then
    return nil, "secret.account is required"
  end

  return require("abcql.secret.linux").lookup(ref.service, ref.account)
end

return M
