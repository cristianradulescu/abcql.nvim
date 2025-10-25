vim.opt.runtimepath:append(".")

require("abcql").setup({
  data_sources = {
    test = "mysql://dbuser:dbpassword@localhost:3306/bookstore",
  },
})

print("=== Testing MySQLAdapter:execute_query() ===\n")

local db = require("abcql.db")
local adapter, err = db.connect("mysql://dbuser:dbpassword@localhost:3306/bookstore")
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
  print("\n=== All tests completed ===")
  vim.cmd("qa!")
end, 2000)
