local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_available()
  return vim.fn.executable("secret-tool") == 1
end

function M.lookup(service, account)
  if not M.is_available() then
    return nil, "secret-tool not found; install libsecret-tools"
  end

  local result = vim.system({ "secret-tool", "lookup", "service", service, "account", account }, { text = true }):wait()
  if result.code ~= 0 then
    local err = trim(result.stderr or "")
    if err == "" then
      err = "secret not found"
    end
    return nil, err
  end

  local secret = trim(result.stdout or "")
  if secret == "" then
    return nil, "secret lookup returned empty value"
  end

  return secret, nil
end

return M
