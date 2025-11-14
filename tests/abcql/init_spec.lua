describe("abcql.nvim", function()
  local abcql
  local original_notify
  local original_has

  before_each(function()
    original_notify = vim.notify
    original_has = vim.fn.has
    vim.notify = function() end

    package.loaded["abcql"] = nil
    package.loaded["abcql.config"] = nil
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.has = original_has
  end)

  describe("version check", function()
    it("should load on Neovim >= 0.11.0", function()
      vim.fn.has = function(version)
        if version == "nvim-0.11.0" then
          return 1
        end
        return 0
      end

      package.loaded["abcql"] = nil
      abcql = require("abcql")

      assert.is_not_nil(abcql)
      assert.is_function(abcql.setup)
    end)

    it("should show error notification on older versions", function()
      local error_shown = false
      vim.notify = function(msg, level)
        if msg:match("requires Neovim") and level == vim.log.levels.ERROR then
          error_shown = true
        end
      end

      vim.fn.has = function(version)
        if version == "nvim-0.11.0" then
          return 0
        end
        return 0
      end

      package.loaded["abcql"] = nil
      abcql = require("abcql")

      assert.is_true(error_shown)
    end)
  end)

  describe("setup", function()
    before_each(function()
      vim.fn.has = function(version)
        if version == "nvim-0.11.0" then
          return 1
        end
        return 0
      end

      package.loaded["abcql"] = nil
      abcql = require("abcql")
    end)

    it("should have setup function", function()
      assert.is_function(abcql.setup)
    end)

    it("should call config setup with options", function()
      local config_setup_called = false
      local passed_opts = nil

      package.loaded["abcql.config"] = {
        setup = function(opts)
          config_setup_called = true
          passed_opts = opts
        end,
      }

      package.loaded["abcql"] = nil
      abcql = require("abcql")

      local test_opts = { data_sources = { test = "mysql://localhost" } }
      abcql.setup(test_opts)

      assert.is_true(config_setup_called)
      assert.are.same(test_opts, passed_opts)
    end)

    it("should accept nil options", function()
      assert.has_no.errors(function()
        abcql.setup(nil)
      end)
    end)

    it("should accept empty options", function()
      assert.has_no.errors(function()
        abcql.setup({})
      end)
    end)

    it("should accept full configuration", function()
      assert.has_no.errors(function()
        abcql.setup({
          data_sources = {
            dev = "mysql://user:pass@localhost:3306/dev_db",
            prod = "mysql://user:pass@prodhost:3306/prod_db",
          },
        })
      end)
    end)
  end)
end)
