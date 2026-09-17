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

    vim.system = function(cmd, _)
      assert.are.same({ "secret-tool", "lookup", "service", "abcql", "account", "prod-db-password" }, cmd)
      return {
        wait = function()
          return { code = 0, stdout = "supersecret\n", stderr = "" }
        end,
      }
    end

    local secret, err = LinuxSecret.lookup("abcql", "prod-db-password")
    assert.is_nil(err)
    assert.are.equal("supersecret", secret)
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
