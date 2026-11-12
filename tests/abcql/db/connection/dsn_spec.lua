local dsn_handler = require("abcql.db.connection.dsn")

describe("dsn_handler", function()
  describe("parse_dsn", function()
    it("should parse valid MySQL DSN with all components", function()
      local dsn = "mysql://user:password@localhost:3306/mydb"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.is_not_nil(parsed)
      assert.are.equal("mysql", parsed.scheme)
      assert.are.equal("user", parsed.user)
      assert.are.equal("password", parsed.password)
      assert.are.equal("localhost", parsed.host)
      assert.are.equal(3306, parsed.port)
      assert.are.equal("mydb", parsed.database)
    end)

    it("should parse DSN without password", function()
      local dsn = "mysql://user@localhost:3306/mydb"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("user", parsed.user)
      assert.is_nil(parsed.password)
    end)

    it("should parse DSN without port", function()
      local dsn = "mysql://user:password@localhost/mydb"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("localhost", parsed.host)
      assert.is_nil(parsed.port)
    end)

    it("should reject a DSN without database", function()
      for _, dsn in ipairs({
        "mysql://user:password@localhost:3306",
        "mysql://user:password@localhost:3306/",
        "mysql://user:password@localhost:3306/?charset=utf8",
      }) do
        local parsed, err = dsn_handler.parse_dsn(dsn)

        assert.is_nil(parsed)
        assert.matches("Missing database name", err)
      end
    end)

    it("should parse DSN with query string options", function()
      local dsn = "mysql://user:password@localhost:3306/mydb?timeout=30&charset=utf8"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("30", parsed.options.timeout)
      assert.are.equal("utf8", parsed.options.charset)
    end)

    it("should handle invalid DSN format", function()
      local dsn = "not-a-valid-dsn"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(parsed)
      assert.is_not_nil(err)
      assert.matches("Invalid DSN format", err)
    end)

    it("should handle empty DSN", function()
      local dsn = ""
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(parsed)
      assert.is_not_nil(err)
    end)

    it("should parse an absolute SQLite file DSN", function()
      local parsed, err = dsn_handler.parse_dsn("sqlite:///var/data/app.db")

      assert.is_nil(err)
      assert.are.equal("sqlite", parsed.scheme)
      assert.are.equal("/var/data/app.db", parsed.path)
      assert.are.equal("main", parsed.database)
      assert.is_nil(parsed.host)
    end)

    it("should resolve a relative SQLite path against the current directory", function()
      local parsed = dsn_handler.parse_dsn("sqlite://data/app.db")

      assert.are.equal(vim.fn.getcwd() .. "/data/app.db", parsed.path)
    end)

    it("should expand ~ in a SQLite path", function()
      local parsed = dsn_handler.parse_dsn("sqlite://~/app.db")

      assert.are.equal(vim.fn.expand("~") .. "/app.db", parsed.path)
    end)

    it("should parse SQLite DSN options", function()
      local parsed = dsn_handler.parse_dsn("sqlite:///app.db?_txlock=immediate")

      assert.are.equal("/app.db", parsed.path)
      assert.are.equal("immediate", parsed.options._txlock)
    end)

    it("should keep :memory: as is", function()
      local parsed = dsn_handler.parse_dsn("sqlite://:memory:")

      assert.are.equal(":memory:", parsed.path)
    end)

    it("should reject a SQLite DSN without a path", function()
      local parsed, err = dsn_handler.parse_dsn("sqlite://")

      assert.is_nil(parsed)
      assert.matches("Invalid DSN format", err)
    end)

    it("should normalize scheme to lowercase", function()
      local dsn = "MySQL://user:password@localhost:3306/mydb"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("mysql", parsed.scheme)
    end)

    it("ends the password at the last @ before the host", function()
      local parsed = assert(dsn_handler.parse_dsn("mysql://u:p@ss@host:3306/db"))
      assert.are.equal("u", parsed.user)
      assert.are.equal("p@ss", parsed.password)
      assert.are.equal("host", parsed.host)
      assert.are.equal(3306, parsed.port)

      parsed = assert(dsn_handler.parse_dsn("mysql://u:p:a{s}s@host/db?x=a@b"))
      assert.are.equal("p:a{s}s", parsed.password)
      assert.are.equal("host", parsed.host)
      assert.are.equal("a@b", parsed.options.x)
    end)

    it("percent-decodes the user and password", function()
      local parsed = assert(dsn_handler.parse_dsn("mysql://us%3Aer:p%40ss%2Fw%3Fr%23d%25@host:3306/db"))
      assert.are.equal("us:er", parsed.user)
      assert.are.equal("p@ss/w?r#d%", parsed.password)
      assert.are.equal("host", parsed.host)
      assert.are.equal("db", parsed.database)
    end)

    it("keeps a % that is not an escape", function()
      assert.are.equal("50%off", dsn_handler.parse_dsn("mysql://u:50%off@h/db").password)
    end)

    it("never puts the password in an error message", function()
      for _, dsn in ipairs({
        "u:hunter2@localhost:3306/db",
        "mysql://u:hunter2@localhost:3306",
        "mysql:///db",
        "sqlite://?key=hunter2",
      }) do
        local parsed, err = dsn_handler.parse_dsn(dsn)
        assert.is_nil(parsed)
        assert.is_nil(err:find("hunter2", 1, true), err)
      end
    end)

    it("should parse PostgreSQL DSN", function()
      local dsn = "postgres://pguser:pgpass@pghost:5432/pgdb"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("postgres", parsed.scheme)
      assert.are.equal("pguser", parsed.user)
      assert.are.equal("pgpass", parsed.password)
      assert.are.equal("pghost", parsed.host)
      assert.are.equal(5432, parsed.port)
      assert.are.equal("pgdb", parsed.database)
    end)
  end)

  describe("split_userinfo", function()
    it("splits at the last @ of the authority and the first :", function()
      assert.are.same(
        { prefix = "mysql://", user = "u", password = "p@ss:x", rest = "h:3306/db?a=b@c" },
        dsn_handler.split_userinfo("mysql://u:p@ss:x@h:3306/db?a=b@c")
      )
      assert.are.same({ prefix = "mysql://", user = "u", rest = "h/db" }, dsn_handler.split_userinfo("mysql://u@h/db"))
      assert.are.same({ prefix = "mysql://", rest = "h/db" }, dsn_handler.split_userinfo("mysql://h/db"))
    end)

    it("ignores file DSNs and strings without a scheme", function()
      assert.is_nil(dsn_handler.split_userinfo("sqlite://a@b.db"))
      assert.is_nil(dsn_handler.split_userinfo("u:p@h/db"))
    end)
  end)

  describe("password helpers", function()
    it("strip_password removes the whole password, special characters included", function()
      assert.are.equal("mysql://u@host:3306/db", dsn_handler.strip_password("mysql://u:p@ss@host:3306/db"))
      assert.are.equal("mysql://u@host/db", dsn_handler.strip_password("mysql://u:p{a}s:s@host/db"))
      assert.are.equal("mysql://u@host/db", dsn_handler.strip_password("mysql://u:@host/db"))
      assert.are.equal("mysql://u@host/db", dsn_handler.strip_password("mysql://u@host/db"))
      assert.are.equal("sqlite:///a:b@c.db", dsn_handler.strip_password("sqlite:///a:b@c.db"))
    end)

    it("set_password percent-encodes, so parse_dsn gives the password back", function()
      for _, password in ipairs({ "p@ss", "a/b?c#d", "100%", "x:y{z}", "${HOME}", " spaced ", "ünï" }) do
        local dsn = dsn_handler.set_password("mysql://u:old@host:3306/db?tls=true", password)
        local parsed = assert(dsn_handler.parse_dsn(dsn))
        assert.are.equal(password, parsed.password)
        assert.are.equal("u", parsed.user)
        assert.are.equal("host", parsed.host)
        assert.are.equal("db", parsed.database)
        assert.are.equal("true", parsed.options.tls)
      end
      assert.are.equal("mysql://u:p%40ss@h/db", dsn_handler.set_password("mysql://u@h/db", "p@ss"))
      -- no user to attach a password to
      assert.are.equal("mysql://h/db", dsn_handler.set_password("mysql://h/db", "pw"))
    end)

    it("mask hides every password character", function()
      assert.are.equal("mysql://u:****@host:3306/db", dsn_handler.mask("mysql://u:p@ss@host:3306/db"))
      assert.are.equal("mysql://u@host/db", dsn_handler.mask("mysql://u@host/db"))
      assert.are.equal("socks5://u:****@proxy:1080", dsn_handler.mask("socks5://u:pw@proxy:1080"))
      assert.are.equal("****@host/db", dsn_handler.mask("u:p@ss@host/db"))
      assert.are.equal("sqlite:///data/app.db", dsn_handler.mask("sqlite:///data/app.db"))
      assert.are.equal("", dsn_handler.mask(nil))
    end)
  end)
end)
