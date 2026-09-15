#!/usr/bin/env bash
# Clones datacharmer/test_db and imports the "employees" sample database into
# the sibling `mysql` service, following that repo's own installation steps:
# https://github.com/datacharmer/test_db#installation
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
MYSQL_USER="${MYSQL_USER:-dbuser}"
REPO_URL="https://github.com/datacharmer/test_db.git"
REPO_DIR="/tmp/test_db"

mysql_root() {
  mysql -h "$MYSQL_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"
}

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Installing git..."
  microdnf install -y git >/dev/null

  echo "Cloning ${REPO_URL}..."
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

already_imported="$(mysql_root -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'employees' AND table_name = 'employees';")"

if [ "$already_imported" = "1" ]; then
  echo "employees database already present, skipping import."
else
  echo "Importing employees database (~300k employees, 2.8M salary rows — this can take a minute)..."
  mysql_root < employees.sql

  echo "Verifying installation..."
  mysql_root -t < test_employees_sha2.sql
fi

echo "Granting privileges on employees.* to ${MYSQL_USER}..."
mysql_root -e "GRANT ALL PRIVILEGES ON employees.* TO '${MYSQL_USER}'@'%'; FLUSH PRIVILEGES;"

echo "Done. employees database is ready."
