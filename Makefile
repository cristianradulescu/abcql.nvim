.PHONY: lint format check test

lint:
	@echo "Running luacheck..."
	@luacheck lua/

format:
	@echo "Running stylua..."
	@stylua --check .

format-fix:
	@echo "Formatting with stylua..."
	@stylua .

check: lint format
	@echo "All checks passed!"

test:
	@echo "Running tests..."
	@nvim --headless --noplugin -u tests/minit.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
