vim.opt.runtimepath:append(".")

require("abcql").setup({
  data_sources = {
    test = "mysql://dbuser:dbpassword@localhost:3306/bookstore",
  },
})

-- Mock vim.ui.select for headless testing to prevent it from hanging
local original_vim_ui_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  -- Simulate selecting the 'test' data source, which is configured above
  on_choice("test")
end

print("=== Testing MySQLAdapter:execute_query() ===\n")

local db = require("abcql.db")
db.activate_datasource(vim.api.nvim_get_current_buf())
print("✓ Activated data source for current buffer")
local active_dsn = db.connectionRegistry:get_datasource(db.get_active_datasource(vim.api.nvim_get_current_buf()))
print("✓ Active DSN: " .. (active_dsn or "nil"))
local adapter, err = db.connectionRegistry:get_connection(active_dsn)
if not adapter then
  print("❌ FAILED to connect: " .. err)
  return
end

print("✓ Got adapter: " .. type(adapter))
print("✓ Adapter type: " .. (adapter.get_command and adapter:get_command() or "unknown"))
print()

-- Test 1: Async query with callback
print("--- Test 1: Async Query (with callback) ---")
adapter:execute_query("SHOW DATABASES", nil, function(results, err_test1)
  if err_test1 then
    print("❌ Async query failed: " .. err_test1)
  else
    print("✓ Async query succeeded!")
    print("Results type: " .. type(results))
    print("Results: " .. vim.inspect(results))
  end
  print()
end)

-- Test 2: Sync query (no callback)
print("--- Test 2: Sync Query (no callback) ---")
local sync_results, sync_err = adapter:execute_query("SELECT User FROM user LIMIT 3", { skip_column_names = false })
if sync_err then
  print("❌ Sync query failed: " .. sync_err)
else
  print("✓ Sync query succeeded!")
  print("Results: " .. vim.inspect(sync_results))
end
print()

-- Test 3: Query with options
print("--- Test 3: Query with skip_column_names option ---")
adapter:execute_query(
  "SELECT 'hello' as greeting, 123 as number",
  { skip_column_names = true },
  function(results, err_test3)
    if err_test3 then
      print("❌ Query failed: " .. err_test3)
    else
      print("✓ Query succeeded!")
      print("Results: " .. vim.inspect(results))
    end
    print()
  end
)

print("\n=== Waiting for async results... ===")

-- Keep running for async callbacks
vim.defer_fn(function()
  vim.ui.select = original_vim_ui_select
  print("\n=== All tests completed ===")
  vim.cmd("qa!")
end, 2000)
