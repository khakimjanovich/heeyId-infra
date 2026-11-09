-- Every database and user heeyID's Postgres holds, run by the one-shot postgres-init on every `up`.
-- Safe to run again: nothing that exists is recreated, and every user's password is set to the one in
-- Vault (secret/env/postgres), so changing it there and running `up` rotates it. The passwords come in
-- as psql variables (postgres/init.sh); none has a default. For now Keycloak's database only; the
-- gateways' come with them.
\set ON_ERROR_STOP on

SELECT 'CREATE USER keycloak' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak')\gexec
SELECT format('ALTER USER keycloak WITH PASSWORD %L', :'keycloak_password')\gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;

SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
