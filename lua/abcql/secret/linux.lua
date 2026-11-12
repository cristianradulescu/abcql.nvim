local M = {}

--- How long a `secret-tool` call may take. It blocks the editor, and a locked
--- keyring may be waiting on an unlock prompt (or never answer at all).
M.TIMEOUT_MS = 20000

--- Exit code vim.system reports when it killed the process at its timeout
local TIMEOUT_CODE = 124

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Error for a `secret-tool` run that did not succeed
--- @param result vim.SystemCompleted
--- @param action string "lookup" | "store"
--- @param fallback string Message when secret-tool printed nothing
--- @return string
local function failure(result, action, fallback)
  if result.code == TIMEOUT_CODE then
    return string.format(
      "secret-tool %s timed out after %ds (is the keyring locked, or its unlock prompt unanswered?)",
      action,
      math.floor(M.TIMEOUT_MS / 1000)
    )
  end
  local err = trim(result.stderr or "")
  if err == "" then
    err = fallback
  end
  return err
end

--- Run secret-tool, giving up after M.TIMEOUT_MS
--- @param cmd string[]
--- @param opts table vim.system options
--- @return vim.SystemCompleted
local function run(cmd, opts)
  opts.timeout = M.TIMEOUT_MS
  -- nil when the killed process left its pipes open (a child still holding them)
  return vim.system(cmd, opts):wait(M.TIMEOUT_MS) or { code = TIMEOUT_CODE, signal = 9, stdout = "", stderr = "" }
end

function M.is_available()
  return vim.fn.executable("secret-tool") == 1
end

function M.lookup(service, account)
  if not M.is_available() then
    return nil, "secret-tool not found; install libsecret-tools"
  end

  local result = run({ "secret-tool", "lookup", "service", service, "account", account }, { text = true })
  if result.code ~= 0 then
    return nil, failure(result, "lookup", "secret not found")
  end

  -- The secret is returned exactly as stored: only the single newline
  -- secret-tool appends when writing to a terminal is dropped, so a password
  -- starting or ending with a space survives.
  local secret = (result.stdout or ""):gsub("\n$", "")
  if secret == "" then
    return nil, "secret lookup returned empty value"
  end

  return secret, nil
end

--- Store a secret in the keyring via `secret-tool store`. The password is
--- passed on stdin, never on the command line.
--- @param service string
--- @param account string
--- @param password string
--- @param label string|nil Human-readable label shown by keyring UIs
--- @return boolean ok
--- @return string|nil err
function M.store(service, account, password, label)
  if not M.is_available() then
    return false, "secret-tool not found; install libsecret-tools"
  end

  label = label or ("abcql " .. account)
  local result = run(
    { "secret-tool", "store", "--label=" .. label, "service", service, "account", account },
    { text = true, stdin = password }
  )
  if result.code ~= 0 then
    return false, failure(result, "store", "secret-tool store failed with code " .. tostring(result.code))
  end

  return true, nil
end

return M
