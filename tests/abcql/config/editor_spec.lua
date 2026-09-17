describe("Config Editor", function()
  local Editor, Config
  local dir
  local original_notify, original_input, original_select, original_secure_read, original_getcwd

  local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  before_each(function()
    original_notify = vim.notify
    original_input = vim.ui.input
    original_select = vim.ui.select
    original_getcwd = vim.fn.getcwd
    original_secure_read = vim.secure.read
    vim.notify = function() end

    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.getcwd = function()
      return dir
    end
    vim.secure.read = function(path)
      local f = io.open(path, "r")
      if not f then
        return nil
      end
      local content = f:read("*a")
      f:close()
      return content
    end

    write_file(
      dir .. "/.abcql.lua",
      table.concat({
        "return {",
        "  datasources = {",
        '    dev = "mysql://u:p@localhost:3306/app",',
        "    prod = {",
        '      dsn = "mysql://u@db:3306/app",',
        '      secret = { service = "abcql", account = "prod-db-password" },',
        "      readonly = true,",
        "    },",
        "  },",
        "}",
        "",
      }, "\n")
    )

    package.loaded["abcql.config"] = nil
    package.loaded["abcql.config.loader"] = nil
    package.loaded["abcql.config.editor"] = nil
    package.loaded["abcql.db"] = nil
    require("abcql.config.loader").TRUST_WRITTEN_FILES = false
    -- Keep registration from touching the real keyring for the prod secret
    package.loaded["abcql.secret"] = {
      lookup = function()
        return "pw", nil
      end,
      is_available = function()
        return false
      end,
      store = function()
        return true, nil
      end,
    }
    Config = require("abcql.config")
    Config.setup({ datasources = { from_setup = "mysql://u@h/db" } })
    Editor = require("abcql.config.editor")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.input = original_input
    vim.ui.select = original_select
    vim.fn.getcwd = original_getcwd
    vim.secure.read = original_secure_read
    package.loaded["abcql.secret"] = nil
    vim.fn.delete(dir, "rf")
  end)

  describe("editable_datasources", function()
    it("lists only datasources that come from a config file", function()
      local items = Editor.editable_datasources()
      local names = vim.tbl_map(function(item)
        return item.name
      end, items)
      assert.are.same({ "dev", "prod" }, names)
      assert.are.equal(dir .. "/.abcql.lua", items[1].path)
    end)
  end)

  describe("read_entry", function()
    it("returns the raw entry for string and table datasources", function()
      local dev = Editor.read_entry(dir .. "/.abcql.lua", "dev")
      assert.are.same({ dsn = "mysql://u:p@localhost:3306/app" }, dev)
      local prod = Editor.read_entry(dir .. "/.abcql.lua", "prod")
      assert.are.equal("mysql://u@db:3306/app", prod.dsn)
      assert.is_true(prod.readonly)
      assert.are.same({ service = "abcql", account = "prod-db-password" }, prod.secret)
    end)

    it("errors for unknown names", function()
      local entry, err = Editor.read_entry(dir .. "/.abcql.lua", "nope")
      assert.is_nil(entry)
      assert.is_not_nil(err:find("not found", 1, true))
    end)
  end)

  describe("update", function()
    it("changes the DSN, toggles readonly and sets the confirm policy, then saves", function()
      local script = {
        ["Update 'dev'"] = { "DSN", "Readonly", "Confirm", "Save" },
      }
      vim.ui.select = function(items, opts, on_choice)
        if opts.prompt:match("^Update 'dev'") then
          local next_field = table.remove(script["Update 'dev'"], 1)
          for _, item in ipairs(items) do
            if item:match("^" .. next_field) then
              on_choice(item)
              return
            end
          end
          error("no menu item for " .. next_field)
        elseif opts.prompt:match("^Confirm policy") then
          on_choice("never")
        elseif opts.prompt:match("^Attach") then
          on_choice("No")
        else
          error("unexpected prompt " .. opts.prompt)
        end
      end
      vim.ui.input = function(opts, on_confirm)
        assert.are.equal("DSN: ", opts.prompt)
        assert.are.equal("mysql://u:p@localhost:3306/app", opts.default)
        on_confirm("mysql://u:p@localhost:3307/app")
      end

      Editor.update("dev")

      local config = dofile(dir .. "/.abcql.lua")
      assert.are.equal("mysql://u:p@localhost:3307/app", config.datasources.dev.dsn)
      assert.is_true(config.datasources.dev.readonly)
      assert.are.equal("never", config.datasources.dev.confirm)
      -- untouched sibling entry
      assert.are.equal("mysql://u@db:3306/app", config.datasources.prod.dsn)

      local ds = require("abcql.db").connectionRegistry:get_datasource("dev")
      assert.is_true(ds.readonly)
      assert.are.equal("never", ds.confirm)
      assert.are.equal(3307, ds.adapter.config.port)
    end)

    it("can move the password back from the keyring into the DSN", function()
      local opened_password_menu = false
      vim.ui.select = function(items, opts, on_choice)
        if opts.prompt:match("^Update 'prod'") then
          if opened_password_menu then
            on_choice("Save")
            return
          end
          opened_password_menu = true
          for _, item in ipairs(items) do
            if item:match("^Password") then
              on_choice(item)
              return
            end
          end
          error("password menu item missing")
        elseif opts.prompt:match("^Password for") then
          for _, item in ipairs(items) do
            if item:match("^Stop using the keyring") then
              on_choice(item)
              return
            end
          end
          error("keyring option missing")
        elseif opts.prompt:match("^Attach") then
          on_choice("No")
        else
          error("unexpected prompt " .. opts.prompt)
        end
      end
      vim.ui.input = function(_, on_confirm)
        on_confirm("plainpw")
      end

      Editor.update("prod")

      local config = dofile(dir .. "/.abcql.lua")
      assert.are.equal("mysql://u:plainpw@db:3306/app", config.datasources.prod.dsn)
      assert.is_nil(config.datasources.prod.secret)
      assert.is_true(config.datasources.prod.readonly)
    end)

    it("refuses names that are not defined in a config file", function()
      local warned
      vim.notify = function(msg)
        warned = msg
      end
      Editor.update("from_setup")
      assert.is_not_nil(warned:find("not defined in a config file", 1, true))
    end)
  end)
end)
