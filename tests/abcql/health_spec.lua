describe("abcql.health", function()
  local Health
  local version = require("abcql.version")
  local original = {}
  local reports

  before_each(function()
    package.loaded["abcql.health"] = nil
    package.loaded["abcql.backend"] = nil
    Health = require("abcql.health")

    original.executable = vim.fn.executable
    original.system = vim.system
    original.get_path = require("abcql.backend").get_path
    reports = {}
    for _, level in ipairs({ "ok", "warn", "error", "info" }) do
      original[level] = vim.health[level]
      vim.health[level] = function(msg, advice)
        table.insert(reports, { level = level, msg = msg, advice = advice })
      end
    end

    require("abcql.backend").get_path = function()
      return "/plugin/bin/abcql-backend"
    end
    vim.fn.executable = function()
      return 1
    end
  end)

  after_each(function()
    vim.fn.executable = original.executable
    vim.system = original.system
    require("abcql.backend").get_path = original.get_path
    for _, level in ipairs({ "ok", "warn", "error", "info" }) do
      vim.health[level] = original[level]
    end
  end)

  local function stub_backend(code, stdout, stderr)
    vim.system = function(cmd, _)
      assert.are.same({ "/plugin/bin/abcql-backend", "version" }, cmd)
      return {
        wait = function()
          return { code = code, stdout = stdout, stderr = stderr }
        end,
      }
    end
  end

  describe("check_backend_binary", function()
    it("is ok when the backend reports the plugin version", function()
      stub_backend(0, "abcql-backend " .. version .. "\n")
      Health.check_backend_binary()

      assert.are.equal(1, #reports)
      assert.are.equal("ok", reports[1].level)
      assert.truthy(reports[1].msg:find(version, 1, true))
    end)

    it("warns when the backend was built from another release", function()
      stub_backend(0, "abcql-backend 0.9.0\n")
      Health.check_backend_binary()

      assert.are.equal(1, #reports)
      assert.are.equal("warn", reports[1].level)
      assert.truthy(reports[1].msg:find("(0.9.0)", 1, true))
      assert.truthy(reports[1].msg:find("(" .. version .. ")", 1, true))
      assert.truthy(reports[1].advice[1]:find("make build", 1, true))
    end)

    it("warns about a dev build", function()
      stub_backend(0, "abcql-backend dev\n")
      Health.check_backend_binary()

      assert.are.equal("warn", reports[1].level)
      assert.truthy(reports[1].msg:find("(dev)", 1, true))
    end)

    it("reports an error when the binary does not run", function()
      stub_backend(1, "", "boom")
      Health.check_backend_binary()

      assert.are.equal(1, #reports)
      assert.are.equal("error", reports[1].level)
    end)

    it("reports an error when the binary is missing", function()
      vim.fn.executable = function()
        return 0
      end
      vim.system = function()
        error("must not run a missing binary")
      end
      Health.check_backend_binary()

      assert.are.equal(1, #reports)
      assert.are.equal("error", reports[1].level)
    end)
  end)
end)
