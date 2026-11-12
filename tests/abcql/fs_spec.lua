local Fs = require("abcql.fs")

describe("abcql.fs", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  local function read(path)
    local f = assert(io.open(path, "r"))
    local content = f:read("*a")
    f:close()
    return content
  end

  describe("write_private", function()
    it("creates the file 0600", function()
      local path = dir .. "/secret.lua"
      assert.is_true(Fs.write_private(path, "return {}\n"))
      assert.are.equal("return {}\n", read(path))
      assert.are.equal("rw-------", vim.fn.getfperm(path))
    end)

    it("replaces an existing file, which ends up 0600", function()
      local path = dir .. "/secret.lua"
      local f = assert(io.open(path, "w"))
      f:write("old content that is longer than the new one")
      f:close()
      vim.uv.fs_chmod(path, 436) -- 0664

      assert.is_true(Fs.write_private(path, "new"))
      assert.are.equal("new", read(path))
      assert.are.equal("rw-------", vim.fn.getfperm(path))
      assert.are.same({ "secret.lua" }, vim.fn.readdir(dir))
    end)

    it("writes through a symlink and keeps the link", function()
      local target = dir .. "/real.lua"
      local link = dir .. "/link.lua"
      assert.is_true(Fs.write_private(target, "a"))
      assert(vim.uv.fs_symlink(target, link))

      assert.is_true(Fs.write_private(link, "b"))
      assert.are.equal("b", read(target))
      assert.are.equal(target, vim.uv.fs_readlink(link))
    end)

    it("fails without touching the target when the directory does not exist", function()
      local ok, err = Fs.write_private(dir .. "/missing/secret.lua", "x")
      assert.is_false(ok)
      assert.is_string(err)
    end)

    it("leaves the old content and no temp file when the rename fails", function()
      local path = dir .. "/secret.lua"
      assert.is_true(Fs.write_private(path, "old"))
      local original_rename = vim.uv.fs_rename
      vim.uv.fs_rename = function()
        return nil, "EXDEV: cross-device link not permitted"
      end
      local ok, err = Fs.write_private(path, "new")
      vim.uv.fs_rename = original_rename

      assert.is_false(ok)
      assert.is_not_nil(err:find("EXDEV", 1, true))
      assert.are.equal("old", read(path))
      assert.are.same({ "secret.lua" }, vim.fn.readdir(dir))
    end)
  end)

  describe("ensure_private_dir", function()
    it("creates missing parents and makes the directory 0700", function()
      local target = dir .. "/a/b/history"
      assert.is_true(Fs.ensure_private_dir(target))
      assert.are.equal("rwx------", vim.fn.getfperm(target))
    end)

    it("tightens an existing directory", function()
      local target = dir .. "/history"
      vim.fn.mkdir(target, "p")
      vim.uv.fs_chmod(target, 509) -- 0775
      assert.is_true(Fs.ensure_private_dir(target))
      assert.are.equal("rwx------", vim.fn.getfperm(target))
    end)
  end)
end)
