#!/usr/bin/env sh
# Wait for PostgreSQL before starting the application.
#
# The host is configurable because it differs between environments: Docker
# Compose calls it "db", while the Helm chart prefixes it with the release
# name. Defaulting to "db" keeps Compose working with no extra configuration.
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"

echo "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"

while ! nc -z "$DB_HOST" "$DB_PORT"; do
    sleep 0.5
done

echo "PostgreSQL is up"

exec "$@"
