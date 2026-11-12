describe("Linux Secret Backend", function()
  local LinuxSecret
  local original_executable
  local original_system

  before_each(function()
    package.loaded["abcql.secret.linux"] = nil
    LinuxSecret = require("abcql.secret.linux")

    original_executable = vim.fn.executable
    original_system = vim.system
  end)

  after_each(function()
    vim.fn.executable = original_executable
    vim.system = original_system
  end)

  it("reports unavailable when secret-tool is missing", function()
    vim.fn.executable = function(name)
      if name == "secret-tool" then
        return 0
      end
      return original_executable(name)
    end

    assert.is_false(LinuxSecret.is_available())
  end)

  it("returns looked up secret when command succeeds", function()
    vim.fn.executable = function(name)
      if name == "secret-tool" then
        return 1
      end
      return original_executable(name)
    end

    local seen_opts, seen_wait
    vim.system = function(cmd, opts)
      assert.are.same({ "secret-tool", "lookup", "service", "abcql", "account", "prod-db-password" }, cmd)
      seen_opts = opts
      return {
        wait = function(_, timeout)
          seen_wait = timeout
          return { code = 0, stdout = "supersecret\n", stderr = "" }
        end,
      }
    end

    local secret, err = LinuxSecret.lookup("abcql", "prod-db-password")
    assert.is_nil(err)
    assert.are.equal("supersecret", secret)
    -- bounded: a locked keyring can't block the editor forever
    assert.are.equal(LinuxSecret.TIMEOUT_MS, seen_opts.timeout)
    assert.are.equal(LinuxSecret.TIMEOUT_MS, seen_wait)
  end)

  it("keeps spaces and drops only the single trailing newline", function()
    vim.fn.executable = function(name)
      return name == "secret-tool" and 1 or original_executable(name)
    end
    local stdout
    vim.system = function()
      return {
        wait = function()
          return { code = 0, stdout = stdout, stderr = "" }
        end,
      }
    end

    stdout = "  spaced pw \n"
    assert.are.equal("  spaced pw ", LinuxSecret.lookup("abcql", "x"))
    stdout = "no newline when piped "
    assert.are.equal("no newline when piped ", LinuxSecret.lookup("abcql", "x"))
    stdout = "pw\n\n"
    assert.are.equal("pw\n", LinuxSecret.lookup("abcql", "x"))
    stdout = "\n"
    local secret, err = LinuxSecret.lookup("abcql", "x")
    assert.is_nil(secret)
    assert.are.equal("secret lookup returned empty value", err)
  end)

  it("reports a timeout clearly", function()
    vim.fn.executable = function(name)
      return name == "secret-tool" and 1 or original_executable(name)
    end
    vim.system = function()
      return {
        wait = function()
          -- what vim.system reports after killing the process at its timeout
          return { code = 124, signal = 9, stdout = "", stderr = "" }
        end,
      }
    end

    local secret, err = LinuxSecret.lookup("abcql", "prod-db-password")
    assert.is_nil(secret)
    assert.is_not_nil(err:find("secret-tool lookup timed out after 20s", 1, true))
    assert.is_not_nil(err:find("keyring locked", 1, true))
  end)

  it("really times out against a hanging secret-tool", function()
    local bin = vim.fn.tempname()
    vim.fn.mkdir(bin, "p")
    local fake = bin .. "/secret-tool"
    local f = assert(io.open(fake, "w"))
    -- exec: one process, like the real secret-tool, so the kill closes its pipes
    f:write("#!/bin/sh\nexec sleep 30\n")
    f:close()
    vim.uv.fs_chmod(fake, 448)
    local original_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. original_path
    local original_timeout = LinuxSecret.TIMEOUT_MS
    LinuxSecret.TIMEOUT_MS = 300

    local started = vim.uv.hrtime()
    local secret, err = LinuxSecret.lookup("abcql", "x")
    local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

    LinuxSecret.TIMEOUT_MS = original_timeout
    vim.env.PATH = original_path
    vim.fn.delete(bin, "rf")

    assert.is_nil(secret)
    assert.is_not_nil(err:find("timed out", 1, true))
    assert.is_true(elapsed_ms < 5000)
  end)

  it("returns error when lookup fails", function()
    vim.fn.executable = function(name)
      if name == "secret-tool" then
        return 1
      end
      return original_executable(name)
    end

    vim.system = function(_, _)
      return {
        wait = function()
          return { code = 1, stdout = "", stderr = "No such secret" }
        end,
      }
    end

    local secret, err = LinuxSecret.lookup("abcql", "missing")
    assert.is_nil(secret)
    assert.are.equal("No such secret", err)
  end)
end)

describe("Linux Secret Backend store", function()
  local LinuxSecret
  local original_executable
  local original_system

  before_each(function()
    package.loaded["abcql.secret.linux"] = nil
    LinuxSecret = require("abcql.secret.linux")
    original_executable = vim.fn.executable
    original_system = vim.system
    vim.fn.executable = function(name)
      if name == "secret-tool" then
        return 1
      end
      return original_executable(name)
    end
  end)

  after_each(function()
    vim.fn.executable = original_executable
    vim.system = original_system
  end)

  it("passes the password on stdin, never in argv", function()
    local seen_cmd, seen_opts
    vim.system = function(cmd, opts)
      seen_cmd, seen_opts = cmd, opts
      return {
        wait = function()
          return { code = 0, stdout = "", stderr = "" }
        end,
      }
    end

    local ok, err = LinuxSecret.store("abcql", "prod-db-password", "s3cret")

    assert.is_true(ok, err)
    assert.are.same(
      { "secret-tool", "store", "--label=abcql prod-db-password", "service", "abcql", "account", "prod-db-password" },
      seen_cmd
    )
    assert.are.equal("s3cret", seen_opts.stdin)
    assert.is_nil(table.concat(seen_cmd, " "):find("s3cret", 1, true))
  end)

  it("returns the error when secret-tool fails", function()
    vim.system = function()
      return {
        wait = function()
          return { code = 1, stdout = "", stderr = "no keyring daemon" }
        end,
      }
    end
    local ok, err = LinuxSecret.store("abcql", "x", "pw")
    assert.is_false(ok)
    assert.are.equal("no keyring daemon", err)
  end)

  it("reports unavailable when secret-tool is missing", function()
    vim.fn.executable = function()
      return 0
    end
    local ok, err = LinuxSecret.store("abcql", "x", "pw")
    assert.is_false(ok)
    assert.is_not_nil(err:find("secret%-tool not found"))
  end)
end)
