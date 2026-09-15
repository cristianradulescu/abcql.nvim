.PHONY: lint format check test test-db-up test-db-down test-db-logs

lint:
	@echo "Running luacheck..."
	@luacheck lua/ tests/

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
	@nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
	@nvim --headless -u NONE -c "luafile tests/minimal_test.lua"

test-db-up:
	@echo "Starting MySQL + importing the employees test database (docker/README.md)..."
	@docker compose up -d
	@docker compose logs -f employees-loader

test-db-down:
	@echo "Stopping the employees test database (add ARGS=-v to also wipe its data)..."
	@docker compose down $(ARGS)

test-db-logs:
	@docker compose logs -f employees-loader
