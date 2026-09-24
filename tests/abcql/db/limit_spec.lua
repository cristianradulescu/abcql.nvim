describe("Limit", function()
  local Limit

  before_each(function()
    package.loaded["abcql.db.limit"] = nil
    Limit = require("abcql.db.limit")
  end)

  --- SQL sent for a statement with an auto-LIMIT of 100
  local function sent(sql)
    return (Limit.apply(sql, 100))
  end

  --- Assert the statement is sent unchanged and not bounded by a LIMIT
  local function untouched(sql)
    local out, status = Limit.apply(sql, 100)
    assert.are.equal(sql, out)
    assert.is_nil(status)
  end

  --- Assert the statement keeps its own LIMIT
  local function explicit(sql)
    local out, status = Limit.apply(sql, 100)
    assert.are.equal(sql, out)
    assert.are.equal("explicit", status)
  end

  describe("adds a LIMIT", function()
    it("to a plain SELECT", function()
      local out, status = Limit.apply("SELECT * FROM t WHERE a = 1", 100)
      assert.are.equal("SELECT * FROM t WHERE a = 1 LIMIT 100", out)
      assert.are.equal("added", status)
    end)

    it("after a trailing string or ORDER BY", function()
      assert.are.equal("select * from t where a = 'x' LIMIT 100", sent("select * from t where a = 'x'"))
      assert.are.equal("select * from t order by `a` desc LIMIT 100", sent("select * from t order by `a` desc"))
    end)

    it("to a WITH ... SELECT", function()
      assert.are.equal(
        "WITH c AS (SELECT * FROM t LIMIT 5) SELECT * FROM c LIMIT 100",
        sent("WITH c AS (SELECT * FROM t LIMIT 5) SELECT * FROM c")
      )
      assert.are.equal(
        "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r LIMIT 100",
        sent("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r")
      )
    end)

    it("to a top-level UNION", function()
      assert.are.equal("SELECT a FROM t UNION SELECT b FROM u LIMIT 100", sent("SELECT a FROM t UNION SELECT b FROM u"))
    end)

    it("when the only LIMIT is nested", function()
      assert.are.equal(
        "SELECT * FROM t WHERE id IN (SELECT id FROM u LIMIT 3) LIMIT 100",
        sent("SELECT * FROM t WHERE id IN (SELECT id FROM u LIMIT 3)")
      )
      assert.are.equal(
        "SELECT * FROM (SELECT * FROM u LIMIT 3) d LIMIT 100",
        sent("SELECT * FROM (SELECT * FROM u LIMIT 3) d")
      )
      assert.are.equal(
        "SELECT a FROM t UNION (SELECT b FROM u LIMIT 5) LIMIT 100",
        sent("SELECT a FROM t UNION (SELECT b FROM u LIMIT 5)")
      )
    end)

    it("ignoring LIMIT in strings, identifiers and comments", function()
      assert.are.equal("SELECT 'limit 5' FROM t LIMIT 100", sent("SELECT 'limit 5' FROM t"))
      assert.are.equal("SELECT `limit` FROM t LIMIT 100", sent("SELECT `limit` FROM t"))
      assert.are.equal("SELECT t.limit FROM t LIMIT 100", sent("SELECT t.limit FROM t"))
      assert.are.equal("SELECT a /* LIMIT 5 */ FROM t LIMIT 100", sent("SELECT a /* LIMIT 5 */ FROM t"))
      assert.are.equal("SELECT a -- LIMIT 5\nFROM t LIMIT 100", sent("SELECT a -- LIMIT 5\nFROM t"))
      assert.are.equal("SELECT a FROM t LIMIT 100 # LIMIT 5", sent("SELECT a FROM t # LIMIT 5"))
    end)

    it("before a trailing semicolon or comment", function()
      assert.are.equal("SELECT * FROM t LIMIT 100;", sent("SELECT * FROM t;"))
      assert.are.equal("SELECT * FROM t LIMIT 100 -- all of it", sent("SELECT * FROM t -- all of it"))
      assert.are.equal("SELECT * FROM t LIMIT 100 /* c */", sent("SELECT * FROM t /* c */"))
      assert.are.equal("SELECT * FROM t LIMIT 100; -- done", sent("SELECT * FROM t; -- done"))
    end)

    it("before a locking clause", function()
      assert.are.equal("SELECT * FROM t LIMIT 100 FOR UPDATE", sent("SELECT * FROM t FOR UPDATE"))
      assert.are.equal("SELECT * FROM t LIMIT 100 FOR SHARE NOWAIT", sent("SELECT * FROM t FOR SHARE NOWAIT"))
      assert.are.equal("SELECT * FROM t LIMIT 100 LOCK IN SHARE MODE", sent("SELECT * FROM t LOCK IN SHARE MODE"))
    end)

    it("before a locking clause's options", function()
      assert.are.equal("SELECT * FROM t LIMIT 100 FOR UPDATE NOWAIT", sent("SELECT * FROM t FOR UPDATE NOWAIT"))
      assert.are.equal("SELECT * FROM t LIMIT 100 FOR SHARE SKIP LOCKED", sent("SELECT * FROM t FOR SHARE SKIP LOCKED"))
      assert.are.equal("SELECT * FROM t LIMIT 100 FOR UPDATE OF t", sent("SELECT * FROM t FOR UPDATE OF t"))
    end)

    it("after index hints that use FOR", function()
      for _, hint in ipairs({ "USE", "FORCE", "IGNORE" }) do
        for _, kind in ipairs({ "INDEX", "KEY" }) do
          for _, target in ipairs({ "JOIN", "ORDER BY", "GROUP BY" }) do
            local sql = string.format("SELECT * FROM t %s %s FOR %s (i) WHERE a = 1", hint, kind, target)
            assert.are.equal(sql .. " LIMIT 100", sent(sql))
            assert.are.equal(sql .. " LIMIT 100 FOR UPDATE", sent(sql .. " FOR UPDATE"))
          end
        end
      end
    end)

    it("treating a lock column as a column", function()
      assert.are.equal("SELECT id, lock FROM jobs LIMIT 100", sent("SELECT id, lock FROM jobs"))
      assert.are.equal("SELECT lock FROM jobs WHERE lock = 1 LIMIT 100", sent("SELECT lock FROM jobs WHERE lock = 1"))
      assert.are.equal(
        "SELECT lock FROM jobs LIMIT 100 LOCK IN SHARE MODE",
        sent("SELECT lock FROM jobs LOCK IN SHARE MODE")
      )
    end)

    it("before a comment that precedes a locking clause", function()
      assert.are.equal("SELECT * FROM t LIMIT 100 -- note\nFOR UPDATE", sent("SELECT * FROM t -- note\nFOR UPDATE"))
      assert.are.equal("SELECT * FROM t LIMIT 100 # note\nFOR UPDATE", sent("SELECT * FROM t # note\nFOR UPDATE"))
      assert.are.equal("SELECT * FROM t LIMIT 100 /* note */ FOR UPDATE", sent("SELECT * FROM t /* note */ FOR UPDATE"))
      assert.are.equal(
        "SELECT * FROM t LIMIT 100 -- note\nLOCK IN SHARE MODE",
        sent("SELECT * FROM t -- note\nLOCK IN SHARE MODE")
      )
      assert.are.equal(
        "SELECT * FROM t LIMIT 100 # note\nLOCK IN SHARE MODE",
        sent("SELECT * FROM t # note\nLOCK IN SHARE MODE")
      )
      assert.are.equal(
        "SELECT * FROM t LIMIT 100 /* note */ LOCK IN SHARE MODE",
        sent("SELECT * FROM t /* note */ LOCK IN SHARE MODE")
      )
    end)
  end)

  describe("keeps an explicit LIMIT", function()
    it("of any size", function()
      explicit("SELECT * FROM titles LIMIT 1000000")
      assert.is_true(Limit.has_limit("SELECT * FROM titles LIMIT 1000000"))
    end)

    it("with OFFSET or MySQL's offset, count form", function()
      explicit("SELECT * FROM t LIMIT 10 OFFSET 20")
      explicit("SELECT * FROM t LIMIT 20, 10")
    end)

    it("on a WITH query, a UNION or a wrapped query", function()
      explicit("WITH c AS (SELECT 1) SELECT * FROM c LIMIT 5")
      explicit("SELECT a FROM t UNION SELECT b FROM u LIMIT 5")
      explicit("(SELECT * FROM t LIMIT 5000)")
    end)

    it("followed by a locking clause or semicolon", function()
      explicit("SELECT * FROM t LIMIT 5 FOR UPDATE")
      explicit("select * from t limit 5;")
    end)
  end)

  describe("leaves alone", function()
    it("statements other than SELECT", function()
      untouched("SHOW TABLES")
      untouched("EXPLAIN SELECT * FROM t")
      untouched("DELETE FROM t WHERE a IN (SELECT a FROM u)")
      untouched("INSERT INTO t SELECT * FROM u")
      untouched("CALL p()")
      untouched("VALUES (1), (2)")
      untouched("WITH c AS (SELECT 1) DELETE FROM t WHERE a IN (SELECT * FROM c)")
    end)

    it("SELECT ... INTO", function()
      untouched("SELECT a INTO @x FROM t")
      untouched("SELECT * FROM t INTO OUTFILE '/tmp/t.csv'")
    end)

    it("several statements, unbalanced parentheses and wrapped queries", function()
      untouched("SELECT 1; SELECT 2")
      untouched("SELECT (1")
      untouched("(SELECT a FROM t) UNION (SELECT b FROM u)")
    end)

    it("everything when the limit is disabled", function()
      assert.are.equal("SELECT 1", (Limit.apply("SELECT 1", 0)))
      assert.are.equal("SELECT 1", (Limit.apply("SELECT 1", false)))
      assert.are.equal("explicit", select(2, Limit.apply("SELECT 1 LIMIT 5", 0)))
    end)
  end)

  describe("for_datasource", function()
    after_each(function()
      package.loaded["abcql.config"] = nil
    end)

    it("prefers the datasource flag", function()
      assert.are.equal(10, Limit.for_datasource({ name = "x", auto_limit = 10 }))
      assert.are.equal(0, Limit.for_datasource({ name = "x", auto_limit = false }))
    end)

    it("falls back to query.auto_limit, then max_rows", function()
      package.loaded["abcql.config"] = { query = { auto_limit = 25, max_rows = 7 } }
      assert.are.equal(25, Limit.for_datasource({ name = "x" }))
      package.loaded["abcql.config"] = { query = { max_rows = 7 } }
      assert.are.equal(7, Limit.for_datasource({ name = "x" }))
      package.loaded["abcql.config"] = { query = { max_rows = 0 } }
      assert.are.equal(0, Limit.for_datasource({ name = "x" }))
      package.loaded["abcql.config"] = { query = {} }
      assert.are.equal(1000, Limit.for_datasource(nil))
    end)
  end)
end)
