std = "luajit"
cache = true

read_globals = {
  "vim",
}

globals = {
  "vim.g",
  "vim.b",
  "vim.w",
  "vim.o",
  "vim.bo",
  "vim.wo",
  "vim.go",
  "vim.env",
}

exclude_files = {
  ".luarocks",
  ".github",
}

ignore = {
  "212/_.*",
  "212/self",
  "212",
}

files["tests/"] = {
  std = "+busted",
  globals = {
    "describe",
    "it",
    "before_each",
    "after_each",
  },
  ignore = {
    "122",
  },
}

max_line_length = 999
