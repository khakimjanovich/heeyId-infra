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

-- The gateways' and the workers' database heeyid (this one, POSTGRES_DB): one schema and one user for each
-- module, both with the module's name. The user owns its schema only, runs its module's migrations there
-- and has no right in any other schema: a module cannot read another module's tables. Schema public is
-- closed above. heeyid_viewer reads every module's tables and changes nothing. The grants on a module's
-- tables come with its migrations, not here.
SELECT format('CREATE USER %I', m) FROM unnest(string_to_array(:'modules', ' ')) m
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = m)\gexec
SELECT 'CREATE USER heeyid_viewer' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'heeyid_viewer')\gexec
SELECT format('ALTER USER access WITH PASSWORD %L', :'access_password')\gexec
SELECT format('ALTER USER customer WITH PASSWORD %L', :'customer_password')\gexec
SELECT format('ALTER USER grants WITH PASSWORD %L', :'grants_password')\gexec
SELECT format('ALTER USER antifraud WITH PASSWORD %L', :'antifraud_password')\gexec
SELECT format('ALTER USER notification WITH PASSWORD %L', :'notification_password')\gexec
SELECT format('ALTER USER catalogue WITH PASSWORD %L', :'catalogue_password')\gexec
SELECT format('ALTER USER staff WITH PASSWORD %L', :'staff_password')\gexec
SELECT format('ALTER USER audit WITH PASSWORD %L', :'audit_password')\gexec
SELECT format('ALTER USER heeyid_viewer WITH PASSWORD %L', :'viewer_password')\gexec

REVOKE ALL ON DATABASE heeyid FROM PUBLIC;
SELECT format('GRANT CONNECT ON DATABASE heeyid TO %I', m) FROM unnest(array_append(string_to_array(:'modules', ' '), 'heeyid_viewer')) m\gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS %1$I AUTHORIZATION %1$I', m) FROM unnest(string_to_array(:'modules', ' ')) m\gexec
SELECT format('REVOKE ALL ON SCHEMA %1$I FROM PUBLIC', m) FROM unnest(string_to_array(:'modules', ' ')) m\gexec
SELECT format('ALTER USER %1$I IN DATABASE heeyid SET search_path = %1$I', m) FROM unnest(string_to_array(:'modules', ' ')) m\gexec

-- heeyid_viewer: SELECT on the tables there are now, and on each table a module user makes later.
SELECT format('GRANT USAGE ON SCHEMA %1$I TO heeyid_viewer', m) FROM unnest(string_to_array(:'modules', ' ')) m\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA %1$I TO heeyid_viewer', m) FROM unnest(string_to_array(:'modules', ' ')) m\gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %1$I IN SCHEMA %1$I GRANT SELECT ON TABLES TO heeyid_viewer', m)
  FROM unnest(string_to_array(:'modules', ' ')) m\gexec

-- The one schema heeyid and its users heeyid_migration and heeyid_app that came before the module schemas:
-- dropped where an installation still has them (no gateway ever wrote there).
SELECT format('DROP OWNED BY %I', rolname) FROM pg_roles WHERE rolname IN ('heeyid_migration', 'heeyid_app')\gexec
SELECT format('DROP USER %I', rolname) FROM pg_roles WHERE rolname IN ('heeyid_migration', 'heeyid_app')\gexec
