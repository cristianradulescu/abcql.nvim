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

    it("should parse DSN without database", function()
      local dsn = "mysql://user:password@localhost:3306"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.is_nil(parsed.database)
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

    it("should normalize scheme to lowercase", function()
      local dsn = "MySQL://user:password@localhost:3306/mydb"
      local parsed, err = dsn_handler.parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("mysql", parsed.scheme)
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
end)
