--- Writing files that may hold credentials or query results: owner-only
--- permissions whatever the umask, and atomic replacement so a failed write
--- never leaves a truncated file behind.
---@class abcql.Fs
local M = {}

--- rw------- for files
M.FILE_MODE = 384 -- 0600
--- rwx------ for directories
M.DIR_MODE = 448 -- 0700

--- Write `content` to `path` with mode 0600, atomically: the data goes to a
--- temporary file in the same directory (created 0600, then chmod'ed to 0600 so
--- the umask can't loosen or tighten it) that is renamed over the target. An
--- existing file therefore ends up 0600 too. When `path` is a symlink the file
--- it points at is replaced and the link is kept.
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil err
function M.write_private(path, content)
  local uv = vim.uv
  local target = uv.fs_realpath(path) or path
  local dir = vim.fn.fnamemodify(target, ":h")
  local base = vim.fn.fnamemodify(target, ":t")

  local fd, tmp = uv.fs_mkstemp(dir .. "/." .. base .. ".abcql-XXXXXX")
  if not fd then
    return false, string.format("Failed to create a temporary file in '%s': %s", dir, tostring(tmp))
  end

  local function fail(what, err)
    if fd then
      uv.fs_close(fd)
    end
    uv.fs_unlink(tmp)
    return false, string.format("Failed to write '%s' (%s): %s", path, what, tostring(err))
  end

  local ok, err = uv.fs_fchmod(fd, M.FILE_MODE)
  if not ok then
    return fail("chmod", err)
  end

  local offset = 0
  while offset < #content do
    local written, write_err = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not written then
      return fail("write", write_err)
    end
    offset = offset + written
  end

  ok, err = uv.fs_fsync(fd)
  if not ok then
    return fail("fsync", err)
  end
  ok, err = uv.fs_close(fd)
  fd = nil
  if not ok then
    return fail("close", err)
  end

  ok, err = uv.fs_rename(tmp, target)
  if not ok then
    return fail("rename", err)
  end
  return true, nil
end

--- Create `dir` (and missing parents) and make `dir` itself 0700, also when it
--- already existed with looser permissions. Parents keep their usual mode.
--- @param dir string
--- @return boolean ok
--- @return string|nil err
function M.ensure_private_dir(dir)
  local uv = vim.uv
  if vim.fn.isdirectory(dir) == 0 then
    local parent = vim.fn.fnamemodify(dir, ":h")
    if vim.fn.isdirectory(parent) == 0 then
      local ok = pcall(vim.fn.mkdir, parent, "p")
      if not ok or vim.fn.isdirectory(parent) == 0 then
        return false, "Failed to create directory: " .. parent
      end
    end
    local ok, err = uv.fs_mkdir(dir, M.DIR_MODE)
    if not ok and vim.fn.isdirectory(dir) == 0 then
      return false, "Failed to create directory: " .. dir .. " (" .. tostring(err) .. ")"
    end
  end

  local stat = uv.fs_stat(dir)
  if stat and bit.band(stat.mode, 511) ~= M.DIR_MODE then
    local ok, err = uv.fs_chmod(dir, M.DIR_MODE)
    if not ok then
      return false, "Failed to restrict permissions of " .. dir .. ": " .. tostring(err)
    end
  end
  return true, nil
end

return M
