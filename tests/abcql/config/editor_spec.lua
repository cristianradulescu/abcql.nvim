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
    -- minimal_init sets shadafile=NONE, so this history is the specs' own
    vim.fn.histdel("input")

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
        -- Pre-filled without the password, which is kept
        assert.are.equal("DSN (its password is kept; change it under Password): ", opts.prompt)
        assert.are.equal("mysql://u@localhost:3306/app", opts.default)
        on_confirm("mysql://u@localhost:3307/app")
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
      vim.ui.input = function()
        error("passwords must not be read with vim.ui.input")
      end
      local prompts = {}
      Editor.read_secret = function(prompt)
        table.insert(prompts, prompt)
        return "plain pw "
      end

      Editor.update("prod")

      assert.are.same({ "Password: " }, prompts)
      local config = dofile(dir .. "/.abcql.lua")
      -- encoded, and not trimmed
      assert.are.equal("mysql://u:plain%20pw%20@db:3306/app", config.datasources.prod.dsn)
      assert.is_nil(config.datasources.prod.secret)
      assert.is_true(config.datasources.prod.readonly)
      local ds = require("abcql.db").connectionRegistry:get_datasource("prod")
      assert.are.equal("plain pw ", ds.adapter.config.password)
    end)

    it("keeps a typed DSN password out of the input history and the menus", function()
      local menus = {}
      local opened = false
      vim.ui.select = function(items, opts, on_choice)
        table.insert(menus, opts.prompt .. " " .. table.concat(items, " | "))
        if opts.prompt:match("^Update 'dev'") then
          if opened then
            on_choice("Save")
            return
          end
          opened = true
          on_choice(items[2]) -- DSN
        elseif opts.prompt:match("^Attach") then
          on_choice("No")
        else
          error("unexpected prompt " .. opts.prompt)
        end
      end
      local typed = "mysql://u:hunter2@localhost:3306/app"
      vim.ui.input = function(_, on_confirm)
        -- what the default vim.ui.input (vim.fn.input) does with typed text
        vim.fn.histadd("input", typed)
        on_confirm(typed)
      end

      Editor.update("dev")

      assert.are_not.equal(typed, vim.fn.histget("input", -1))
      for i = 1, vim.fn.histnr("input") do
        assert.is_nil(vim.fn.histget("input", i):find("hunter2", 1, true))
      end
      -- the menu shown after the change masks the password
      local last_update
      for _, menu in ipairs(menus) do
        if menu:match("^Update 'dev'") then
          last_update = menu
        end
      end
      assert.is_nil(last_update:find("hunter2", 1, true))
      assert.is_not_nil(last_update:find("DSN: mysql://u:****@localhost:3306/app", 1, true))
      assert.are.equal(typed, dofile(dir .. "/.abcql.lua").datasources.dev)
    end)

    it("reads a password with inputsecret, which keeps it out of the input history", function()
      vim.fn.histadd("input", "before")
      vim.api.nvim_feedkeys("hunter2\r", "t", false)
      local password = Editor.read_secret("Password: ")
      assert.are.equal("hunter2", password)
      assert.are.equal("before", vim.fn.histget("input", -1))
    end)

    it("removes a DSN typed into the real vim.ui.input from the input history", function()
      vim.ui.input = original_input
      local opened = false
      vim.ui.select = function(items, opts, on_choice)
        if opts.prompt:match("^Update 'dev'") then
          if opened then
            on_choice("Save")
            return
          end
          opened = true
          on_choice(items[2]) -- DSN
        elseif opts.prompt:match("^Attach") then
          on_choice("No")
        end
      end
      -- <C-u> clears the pre-filled DSN, then a DSN with an inline password is typed
      vim.api.nvim_feedkeys("\21mysql://u:hunter2@localhost:3306/app\r", "t", false)
      Editor.update("dev")

      assert.are.equal("mysql://u:hunter2@localhost:3306/app", dofile(dir .. "/.abcql.lua").datasources.dev)
      for i = 1, vim.fn.histnr("input") do
        assert.is_nil(vim.fn.histget("input", i):find("hunter2", 1, true))
      end
    end)
  end)

  describe("add", function()
    local function script_select(answers)
      vim.ui.select = function(items, opts, on_choice)
        for prompt, answer in pairs(answers) do
          if opts.prompt:find(prompt, 1, true) then
            for _, item in ipairs(items) do
              if item:find(answer, 1, true) then
                on_choice(item)
                return
              end
            end
            error("no item " .. answer .. " in " .. table.concat(items, " | "))
          end
        end
        error("unexpected prompt " .. opts.prompt)
      end
    end

    it("offers a password-less DSN and asks for the password separately", function()
      script_select({
        ["Password for 'staging'"] = "saved in the DSN",
        ["Options for 'staging'"] = "None",
        ["Attach"] = "No",
      })
      local inputs = {}
      vim.ui.input = function(opts, on_confirm)
        table.insert(inputs, opts)
        if opts.prompt == "Datasource name: " then
          on_confirm("staging")
        else
          on_confirm("mysql://u@db:3306/app")
        end
      end
      Editor.read_secret = function()
        return "p@ss/w{rd}"
      end

      Editor.add("local")

      assert.are.equal("mysql://user@localhost:3306/database", inputs[2].default)
      local config = dofile(dir .. "/.abcql.lua")
      assert.are.equal("mysql://u:p%40ss%2Fw%7Brd%7D@db:3306/app", config.datasources.staging)
      local ds = require("abcql.db").connectionRegistry:get_datasource("staging")
      assert.are.equal("p@ss/w{rd}", ds.adapter.config.password)
      assert.are.equal("rw-------", vim.fn.getfperm(dir .. "/.abcql.lua"))
      -- the siblings are untouched
      assert.are.equal("mysql://u:p@localhost:3306/app", config.datasources.dev)
      assert.are.equal("mysql://u@db:3306/app", config.datasources.prod.dsn)
    end)

    it("stores an entered password in the keyring only", function()
      local stored
      package.loaded["abcql.secret"].is_available = function()
        return true
      end
      package.loaded["abcql.secret"].store = function(ref, password)
        stored = { ref = ref, password = password }
        return true, nil
      end
      script_select({
        ["Password for 'staging'"] = "keyring",
        ["Options for 'staging'"] = "None",
        ["Attach"] = "No",
      })
      vim.ui.input = function(opts, on_confirm)
        on_confirm(opts.prompt == "Datasource name: " and "staging" or "mysql://u@db:3306/app")
      end
      Editor.read_secret = function()
        return "s3cret"
      end

      Editor.add("local")

      assert.are.same({ service = "abcql", account = "staging-db-password" }, stored.ref)
      assert.are.equal("s3cret", stored.password)
      local entry = dofile(dir .. "/.abcql.lua").datasources.staging
      assert.are.equal("mysql://u@db:3306/app", entry.dsn)
      assert.are.same({ service = "abcql", account = "staging-db-password" }, entry.secret)
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
