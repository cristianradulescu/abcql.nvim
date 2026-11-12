.PHONY: lint lint-backend format format-fix check test test-backend build version test-db-up test-db-down test-db-logs

# The release version lives in lua/abcql/version.lua; `build` stamps it into abcql-backend.
VERSION := $(shell sed -n 's/^return "\(.*\)"$$/\1/p' lua/abcql/version.lua)

lint: lint-backend
	@echo "Running luacheck..."
	@luacheck lua/ tests/

lint-backend:
	@echo "Running gofmt/go vet on backend..."
	@test -z "$$(gofmt -l ./backend)" || (gofmt -l ./backend && exit 1)
	@cd backend && go vet ./...

format:
	@echo "Running stylua..."
	@stylua --check .

format-fix:
	@echo "Formatting with stylua..."
	@stylua .

check: lint format
	@echo "All checks passed!"

build:
	@test -n "$(VERSION)" || (echo "Could not read the version from lua/abcql/version.lua" && exit 1)
	@echo "Building abcql-backend $(VERSION)..."
	@mkdir -p bin
	@cd backend && go build -ldflags "-X main.version=$(VERSION)" -o ../bin/abcql-backend .

version:
	@echo "$(VERSION)"

test: test-backend
	@echo "Running tests..."
	@nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
	@nvim --headless -u NONE -c "luafile tests/minimal_test.lua"

test-backend:
	@echo "Running backend (Go) tests..."
	@cd backend && go test ./...

test-db-up:
	@echo "Starting MySQL + importing the employees test database (docker/README.md)..."
	@docker compose up -d
	@docker compose logs -f employees-loader

test-db-down:
	@echo "Stopping the employees test database (add ARGS=-v to also wipe its data)..."
	@docker compose down $(ARGS)

test-db-logs:
	@docker compose logs -f employees-loader
