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

  describe("dangerous", function()
    local function message(sql)
      local danger = Statements.dangerous(sql)
      return danger and danger.message
    end

    it("flags UPDATE/DELETE without a top-level WHERE", function()
      assert.are.equal("DELETE without WHERE affects every row in orders", message("DELETE FROM orders"))
      assert.are.equal("UPDATE without WHERE affects every row in t", message("update t set a = 1"))
      assert.are.equal(
        "DELETE without WHERE affects every row in `shop`.`orders`",
        message("delete from `shop`.`orders`")
      )
      assert.is_nil(Statements.dangerous("DELETE FROM t WHERE id = 1"))
      assert.is_nil(Statements.dangerous("update t set a = 1\nwhere id in (select id from u)"))
    end)

    it("ignores WHERE in subqueries, CTE bodies, strings and comments", function()
      assert.is_not_nil(Statements.dangerous("UPDATE t SET a = (SELECT x FROM y WHERE z = 1)"))
      assert.is_not_nil(Statements.dangerous("UPDATE t SET a = 'where' -- where\n/* where */"))
      local danger = Statements.dangerous("WITH x AS (SELECT 1 WHERE 1) DELETE FROM t")
      assert.are.equal("DELETE", danger.keyword)
      assert.are.equal(30, danger.pos)
      assert.is_nil(Statements.dangerous("WITH x AS (SELECT 1) DELETE FROM t WHERE id IN (SELECT * FROM x)"))
    end)

    it("does not flag UPDATE/DELETE restricted by an inner join", function()
      assert.is_nil(Statements.dangerous("UPDATE a JOIN b ON a.id = b.id SET a.x = b.y"))
      assert.is_nil(Statements.dangerous("UPDATE a INNER JOIN b USING (id) SET a.x = 1"))
      assert.is_nil(Statements.dangerous("UPDATE a STRAIGHT_JOIN b ON a.id = b.id SET a.x = 1"))
      assert.is_nil(Statements.dangerous("DELETE t FROM t JOIN u ON t.id = u.id"))
      assert.is_nil(Statements.dangerous("DELETE FROM a USING a JOIN b ON a.id = b.id"))
      assert.is_nil(Statements.dangerous("DELETE t FROM t JOIN u ON t.id = u.id WHERE 1=1"))
    end)

    it("still flags joins that do not restrict the target", function()
      assert.are.equal("a", Statements.dangerous("UPDATE a, b SET a.x = b.y").table)
      assert.is_not_nil(Statements.dangerous("UPDATE a CROSS JOIN b SET a.x = 1"))
      assert.is_not_nil(Statements.dangerous("UPDATE a JOIN b SET a.x = 1"))
      assert.is_not_nil(Statements.dangerous("UPDATE a LEFT JOIN b ON a.id = b.id SET a.x = 1"))
      assert.is_not_nil(Statements.dangerous("DELETE a FROM a LEFT OUTER JOIN b ON a.id = b.id"))
      assert.are.equal("a", Statements.dangerous("DELETE FROM a USING a, b").table)
      assert.are.equal("t", Statements.dangerous("UPDATE LOW_PRIORITY IGNORE t SET a = 1").table)
    end)

    it("treats only literal always-true conditions as missing", function()
      assert.are.equal("DELETE with WHERE 1 affects every row in t", message("DELETE FROM t WHERE 1"))
      assert.is_not_nil(Statements.dangerous("DELETE FROM t WHERE 1 = 1 LIMIT 3"))
      assert.is_not_nil(Statements.dangerous("update t set a = 1 where true"))
      assert.is_nil(Statements.dangerous("DELETE FROM t WHERE 1=1 AND id = 2"))
      assert.is_nil(Statements.dangerous("DELETE FROM t WHERE (1=1)"))
      assert.is_nil(Statements.dangerous("DELETE FROM t WHERE 2 > 1"))
    end)

    it("flags a LIMIT without WHERE with an accurate row count", function()
      assert.are.equal("DELETE without WHERE affects up to 5 arbitrary rows in t", message("DELETE FROM t LIMIT 5"))
      assert.are.equal(
        "DELETE with WHERE 1=1 affects up to 5 arbitrary rows in t",
        message("DELETE FROM t WHERE 1 = 1 LIMIT 5")
      )
      assert.are.equal("DELETE without WHERE affects up to 10 rows in t", message("DELETE FROM t ORDER BY id LIMIT 10"))
      assert.are.equal(
        "UPDATE without WHERE affects arbitrary rows (LIMIT) in t",
        message("UPDATE t SET a = 1 LIMIT ?")
      )
    end)

    it("records the column where each statement starts", function()
      local statements = Statements.scan("DELETE FROM t WHERE id=1; DELETE FROM t;\n  /* c */ SELECT 1")
      assert.are.same({ 0, 26, 10 }, {
        statements[1].start_col,
        statements[2].start_col,
        statements[3].start_col,
      })
    end)

    it("flags TRUNCATE but not DROP or other statements", function()
      assert.are.equal("TRUNCATE removes every row in logs", message("TRUNCATE TABLE logs"))
      assert.are.equal("TRUNCATE", Statements.dangerous("truncate logs").keyword)
      assert.is_nil(Statements.dangerous("DROP TABLE t"))
      assert.is_nil(Statements.dangerous("INSERT INTO t VALUES (1) ON DUPLICATE KEY UPDATE a = 1"))
      assert.is_nil(Statements.dangerous("SELECT * FROM t"))
      assert.is_nil(Statements.dangerous(""))
    end)
  end)

  describe("implicit_commit", function()
    it("names the keyword that commits the open transaction", function()
      for sql, want in pairs({
        ["BEGIN"] = "BEGIN",
        ["-- c\nstart transaction"] = "START",
        ["drop table t"] = "DROP",
        ["ALTER TABLE t ADD c int"] = "ALTER",
        ["truncate t"] = "TRUNCATE",
        ["LOCK TABLES t WRITE"] = "LOCK",
        ["grant select on *.* to u"] = "GRANT",
        ["SET autocommit = 1"] = "SET autocommit = 1",
        ["set @@session.autocommit=ON"] = "SET autocommit = 1",
      }) do
        assert.are.equal(want, Statements.implicit_commit(sql), sql)
      end
    end)

    it("ignores everything else", function()
      for _, sql in ipairs({
        "SELECT 1",
        "UPDATE t SET a = 1",
        "CREATE TEMPORARY TABLE t (a int)",
        "DROP TEMPORARY TABLE t",
        "SET autocommit = 0",
        "SET @a = 1",
        "COMMIT",
      }) do
        assert.is_nil(Statements.implicit_commit(sql), sql)
      end
    end)
  end)
end)
