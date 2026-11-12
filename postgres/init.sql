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

-- The gateways' and the workers' database heeyid (this one, POSTGRES_DB): one schema for each module and
-- one user <module>_user that owns it. The user runs its module's migrations there and has no right in any
-- other schema: a module cannot read another module's tables. Schema public is closed above.
-- heeyid_viewer reads every module's tables and changes nothing. The grants on a module's tables come
-- with its migrations, not here.
SELECT format('CREATE USER %I', u) FROM (VALUES
  ('access_user'), ('customer_user'), ('grants_user'), ('antifraud_user'), ('notification_user'),
  ('catalogue_user'), ('staff_user'), ('audit_user'), ('heeyid_viewer')) v(u)
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = u)\gexec
SELECT format('ALTER USER %I WITH PASSWORD %L', u, p) FROM (VALUES
  ('access_user', :'access_password'), ('customer_user', :'customer_password'),
  ('grants_user', :'grants_password'), ('antifraud_user', :'antifraud_password'),
  ('notification_user', :'notification_password'), ('catalogue_user', :'catalogue_password'),
  ('staff_user', :'staff_password'), ('audit_user', :'audit_password'),
  ('heeyid_viewer', :'viewer_password')) v(u, p)\gexec

REVOKE ALL ON DATABASE heeyid FROM PUBLIC;
GRANT CONNECT ON DATABASE heeyid TO access_user, customer_user, grants_user, antifraud_user, notification_user,
  catalogue_user, staff_user, audit_user, heeyid_viewer;
DO $$
DECLARE m text;
BEGIN
  FOREACH m IN ARRAY ARRAY['access', 'customer', 'grants', 'antifraud', 'notification', 'catalogue', 'staff', 'audit'] LOOP
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', m, m || '_user');
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', m);
    EXECUTE format('ALTER USER %I IN DATABASE heeyid SET search_path = %I', m || '_user', m);
    -- heeyid_viewer: SELECT on the tables there are now, and on each table the module's user makes later.
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO heeyid_viewer', m);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO heeyid_viewer', m);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO heeyid_viewer', m || '_user', m);
  END LOOP;
END $$;
