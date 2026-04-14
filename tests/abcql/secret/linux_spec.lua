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
