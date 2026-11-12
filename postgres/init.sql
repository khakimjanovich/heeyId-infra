-- Every database and user heeyID's Postgres holds, run by the one-shot postgres-init on every `up`.
-- Safe to run again: nothing that exists is recreated, and every user's password is set to the one in
-- Vault (secret/env/postgres), so changing it there and running `up` rotates it. The passwords come in
-- as psql variables (postgres/init.sh); none has a default.
\set ON_ERROR_STOP on

-- Keycloak's database.
SELECT 'CREATE USER keycloak' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak')\gexec
SELECT format('ALTER USER keycloak WITH PASSWORD %L', :'keycloak_password')\gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;

SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
REVOKE ALL ON DATABASE keycloak FROM PUBLIC; -- its owner keycloak only

-- The gateways' database heeyid (this one, POSTGRES_DB), SAD §10.7 HID-30. Two users:
--   heeyid_migration  owns schema heeyid: the gateways' migrations create the tables with it.
--   heeyid_app        what the customer gateway, the admin gateway and the workers connect with:
--                     USAGE on the schema only, never CREATE.
-- The grants on the tables come with the gateway migrations, not here. There heeyid_app gets no UPDATE
-- or DELETE on the append-only tables (audit_event, SAD).
SELECT 'CREATE USER heeyid_migration' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'heeyid_migration')\gexec
SELECT format('ALTER USER heeyid_migration WITH PASSWORD %L', :'heeyid_migration_password')\gexec
SELECT 'CREATE USER heeyid_app' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'heeyid_app')\gexec
SELECT format('ALTER USER heeyid_app WITH PASSWORD %L', :'heeyid_app_password')\gexec

REVOKE ALL ON DATABASE heeyid FROM PUBLIC;
GRANT CONNECT ON DATABASE heeyid TO heeyid_migration, heeyid_app;
CREATE SCHEMA IF NOT EXISTS heeyid AUTHORIZATION heeyid_migration;
GRANT USAGE ON SCHEMA heeyid TO heeyid_app;
ALTER USER heeyid_migration IN DATABASE heeyid SET search_path = heeyid;
ALTER USER heeyid_app IN DATABASE heeyid SET search_path = heeyid;
