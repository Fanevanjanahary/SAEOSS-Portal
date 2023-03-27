#!/bin/bash

# Creates an additional user and restricts access to the DB.
# This is an adaptation of the CKAN datastore's `set_permissions.sql` template
# script, as found on the CKAN datastore source code

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" << EOSQL

-- create read-only user
CREATE USER "$DATASTORE_READONLY_USER" WITH PASSWORD '$DATASTORE_READONLY_USER_PASSWORD';

-- revoke permissions for the read-only user
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE USAGE ON SCHEMA public FROM PUBLIC;

-- grant select permissions for read-only user
GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$DATASTORE_READONLY_USER";
GRANT USAGE ON SCHEMA public TO "$DATASTORE_READONLY_USER";

-- grant access to current tables and views to read-only user
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$DATASTORE_READONLY_USER";

-- grant access to new tables and views by default
ALTER DEFAULT PRIVILEGES FOR USER "$POSTGRES_USER" IN SCHEMA public
   GRANT SELECT ON TABLES TO "$DATASTORE_READONLY_USER";

-- a view for listing valid table (resource id) and view names
CREATE OR REPLACE VIEW "_table_metadata" AS
    SELECT DISTINCT
        substr(md5(dependee.relname || COALESCE(dependent.relname, '')), 0, 17) AS "_id",
        dependee.relname AS name,
        dependee.oid AS oid,
        dependent.relname AS alias_of
    FROM
        pg_class AS dependee
        LEFT OUTER JOIN pg_rewrite AS r ON r.ev_class = dependee.oid
        LEFT OUTER JOIN pg_depend AS d ON d.objid = r.oid
        LEFT OUTER JOIN pg_class AS dependent ON d.refobjid = dependent.oid
    WHERE
        (dependee.oid != dependent.oid OR dependent.oid IS NULL) AND
        -- is a table (from pg_tables view definition)
        -- or is a view (from pg_views view definition)
        (dependee.relkind = 'r'::"char" OR dependee.relkind = 'v'::"char")
        AND dependee.relnamespace = (
            SELECT oid FROM pg_namespace WHERE nspname='public')
    ORDER BY dependee.oid DESC;
GRANT SELECT ON "_table_metadata" TO "$DATASTORE_READONLY_USER";

-- _full_text fields are now updated by a trigger when set to NULL
CREATE OR REPLACE FUNCTION populate_full_text_trigger() RETURNS trigger
AS \$body\$
    BEGIN
        IF NEW._full_text IS NOT NULL THEN
            RETURN NEW;
        END IF;
        NEW._full_text := (
            SELECT to_tsvector(string_agg(value, ' '))
            FROM json_each_text(row_to_json(NEW.*))
            WHERE key NOT LIKE '\_%');
        RETURN NEW;
    END;
\$body\$ LANGUAGE plpgsql;

-- migrate existing tables that don't have full text trigger applied
DO \$body\$
    BEGIN
        EXECUTE coalesce(
            (SELECT string_agg(
                'CREATE TRIGGER zfulltext BEFORE INSERT OR UPDATE ON ' ||
                quote_ident(relname) || ' FOR EACH ROW EXECUTE PROCEDURE ' ||
                'populate_full_text_trigger();', ' ')
            FROM pg_class
            LEFT OUTER JOIN pg_trigger AS t
                ON t.tgrelid = relname::regclass AND t.tgname = 'zfulltext'
            WHERE relkind = 'r'::"char" AND t.tgname IS NULL
                AND relnamespace = (
                    SELECT oid FROM pg_namespace WHERE nspname='public')),
            'SELECT 1;');
    END;
\$body\$;


EOSQL
