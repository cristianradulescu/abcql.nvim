describe("abcql.backend", function()
  local Backend
  local original_executable
  local original_system
  local original_config

  before_each(function()
    package.loaded["abcql.backend"] = nil
    Backend = require("abcql.backend")

    original_executable = vim.fn.executable
    original_system = vim.system
    original_config = package.loaded["abcql.config"]
  end)

  after_each(function()
    vim.fn.executable = original_executable
    vim.system = original_system
    package.loaded["abcql.config"] = original_config
  end)

  local function stub_config(backend_opts)
    package.loaded["abcql.config"] = { backend = backend_opts }
  end

  describe("get_path", function()
    it("returns the configured override path when set", function()
      stub_config({ path = "/custom/abcql-backend" })
      assert.are.equal("/custom/abcql-backend", Backend.get_path())
    end)

    it("falls back to the runtime file lookup when unset", function()
      stub_config({ path = nil })
      local original_get_runtime_file = vim.api.nvim_get_runtime_file
      vim.api.nvim_get_runtime_file = function(name, _)
        assert.are.equal("bin/abcql-backend", name)
        return { "/plugin/root/bin/abcql-backend" }
      end

      local path = Backend.get_path()

      vim.api.nvim_get_runtime_file = original_get_runtime_file
      assert.are.equal("/plugin/root/bin/abcql-backend", path)
    end)
  end)

  describe("invoke_sync", function()
    it("errors when the binary is missing", function()
      stub_config({ path = "/nonexistent/abcql-backend" })
      vim.fn.executable = function()
        return 0
      end

      local response, err = Backend.invoke_sync({ sql = "select 1" })

      assert.is_nil(response)
      assert.is_not_nil(err:match("abcql%-backend not found"))
    end)

    it("decodes a successful JSON response", function()
      stub_config({ path = "/usr/local/bin/abcql-backend" })
      vim.fn.executable = function()
        return 1
      end

      vim.system = function(cmd, opts)
        assert.are.same({ "/usr/local/bin/abcql-backend", "exec" }, cmd)
        assert.is_not_nil(opts.stdin:match('"sql":"select 1"'))
        return {
          wait = function()
            return {
              code = 0,
              stdout = '{"query_type":"select","headers":["a"],"rows":[["1"]],"row_count":1}',
              stderr = "",
            }
          end,
        }
      end

      local response, err = Backend.invoke_sync({ sql = "select 1" })

      assert.is_nil(err)
      assert.are.equal("select", response.query_type)
      assert.are.same({ "a" }, response.headers)
      assert.are.same({ { "1" } }, response.rows)
    end)

    it("returns the backend-reported error even on a JSON response", function()
      stub_config({ path = "/usr/local/bin/abcql-backend" })
      vim.fn.executable = function()
        return 1
      end

      vim.system = function(_, _)
        return {
          wait = function()
            return { code = 1, stdout = '{"error":"table does not exist","row_count":0}', stderr = "" }
          end,
        }
      end

      local response, err = Backend.invoke_sync({ sql = "select * from nope" })

      assert.is_nil(response)
      assert.are.equal("table does not exist", err)
    end)

    it("falls back to stderr when stdout is not valid JSON", function()
      stub_config({ path = "/usr/local/bin/abcql-backend" })
      vim.fn.executable = function()
        return 1
      end

      vim.system = function(_, _)
        return {
          wait = function()
            return { code = 1, stdout = "", stderr = "segmentation fault" }
          end,
        }
      end

      local response, err = Backend.invoke_sync({ sql = "select 1" })

      assert.is_nil(response)
      assert.are.equal("segmentation fault", err)
    end)
  end)

  describe("invoke", function()
    it("decodes a successful JSON response asynchronously", function()
      stub_config({ path = "/usr/local/bin/abcql-backend" })
      vim.fn.executable = function()
        return 1
      end

      vim.system = function(cmd, opts, on_exit)
        assert.are.same({ "/usr/local/bin/abcql-backend", "exec" }, cmd)
        on_exit({
          code = 0,
          stdout = '{"query_type":"write","headers":[],"rows":[],"row_count":0,"affected_rows":2}',
          stderr = "",
        })
      end

      -- vim.schedule runs synchronously enough in headless tests for this assertion
      local done = false
      Backend.invoke({ sql = "update t set x=1" }, function(response, err)
        assert.is_nil(err)
        assert.are.equal("write", response.query_type)
        assert.are.equal(2, response.affected_rows)
        done = true
      end)

      vim.wait(100, function()
        return done
      end)
      assert.is_true(done)
    end)
  end)
end)
