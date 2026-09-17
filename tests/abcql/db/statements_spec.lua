local Statements = require("abcql.db.statements")

describe("Statements", function()
  describe("scan", function()
    it("splits on semicolons at end of line", function()
      local stmts = Statements.scan("select 1;\nselect 2;")
      assert.are.equal(2, #stmts)
      assert.are.equal("select 1", stmts[1].text)
      assert.are.equal("select 2", stmts[2].text)
      assert.are.equal(1, stmts[1].start_line)
      assert.are.equal(2, stmts[2].start_line)
    end)

    it("splits multiple statements on one line", function()
      local stmts = Statements.scan("select 1; select 2;")
      assert.are.equal(2, #stmts)
      assert.are.equal("select 2", stmts[2].text)
      assert.are.equal(1, stmts[2].start_line)
    end)

    it("ignores semicolons inside strings, identifiers and comments", function()
      local sql = table.concat({
        "select 'a;b', \"c;d\", `e;f` -- trailing; comment",
        "from t /* block; comment */;",
        "# hash; comment",
        "select 2;",
      }, "\n")
      local stmts = Statements.scan(sql)
      assert.are.equal(2, #stmts)
      assert.is_not_nil(stmts[1].text:find("'a;b'", 1, true))
      assert.are.equal(1, stmts[1].start_line)
      assert.are.equal(2, stmts[1].end_line)
      assert.are.equal("select 2", stmts[2].text)
      assert.are.equal(4, stmts[2].start_line)
    end)

    it("handles escaped and doubled quotes", function()
      local stmts = Statements.scan([[select 'it''s; fine', 'back\'; slash'; select 2]])
      assert.are.equal(2, #stmts)
      assert.are.equal("select 2", stmts[2].text)
    end)

    it("keeps a trailing statement without semicolon", function()
      local stmts = Statements.scan("select 1;\n\nselect 2")
      assert.are.equal(2, #stmts)
      assert.are.equal("select 2", stmts[2].text)
      assert.are.equal(3, stmts[2].start_line)
      assert.are.equal(3, stmts[2].end_line)
    end)

    it("skips comment-only and blank chunks", function()
      local stmts = Statements.scan("-- header\n\n;\n/* nothing */;\nselect 1;")
      assert.are.equal(1, #stmts)
      assert.are.equal("select 1", stmts[1].text)
      assert.are.equal(5, stmts[1].start_line)
    end)

    it("points start_line at the first non-blank line of a statement", function()
      local stmts = Statements.scan("select 1;\n\n\nselect\n  2;")
      assert.are.equal(4, stmts[2].start_line)
      assert.are.equal(5, stmts[2].end_line)
      assert.are.equal("select\n  2", stmts[2].text)
    end)
  end)

  describe("at_line", function()
    local stmts = Statements.scan("select 1;\n\nselect\n2;\n\n\nselect 3;")

    it("returns the statement containing the line", function()
      assert.are.equal("select\n2", Statements.at_line(stmts, 4).text)
    end)

    it("returns the following statement for a blank line", function()
      assert.are.equal("select\n2", Statements.at_line(stmts, 2).text)
      assert.are.equal("select 3", Statements.at_line(stmts, 6).text)
    end)

    it("returns nil past the last statement", function()
      assert.is_nil(Statements.at_line(stmts, 99))
    end)
  end)

  describe("split_buffer", function()
    it("splits the buffer contents", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;", "select 2;" })
      local stmts = Statements.split_buffer(buf)
      assert.are.equal(2, #stmts)
      assert.are.equal("select 2", stmts[2].text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("is_write", function()
    it("treats reads as non-write", function()
      for _, sql in ipairs({
        "select 1",
        "SHOW TABLES",
        "describe t",
        "explain select 1",
        "with x as (select 1) select * from x",
        "(select 1)",
      }) do
        assert.is_false(Statements.is_write(sql), sql)
      end
    end)

    it("treats DML and DDL as writes", function()
      for _, sql in ipairs({
        "insert into t values (1)",
        "UPDATE t set x=1",
        "delete from t",
        "drop table t",
        "alter table t add c int",
        "truncate t",
        "create table t (x int)",
        "set foreign_key_checks=0",
      }) do
        assert.is_true(Statements.is_write(sql), sql)
      end
    end)

    it("ignores leading comments", function()
      assert.is_true(Statements.is_write("-- note\n/* more */ delete from t"))
      assert.is_false(Statements.is_write("-- delete\nselect 1"))
    end)

    it("returns false for blank input", function()
      assert.is_false(Statements.is_write(""))
      assert.is_false(Statements.is_write("-- only a comment"))
    end)
  end)
end)
