-- Install PostgREST schema-cache auto-reload triggers on the CSV database.
--
-- The tabular API (api-tabular) reads parsed CSV tables through PostgREST. Every time
-- hydra parses a resource it creates a new table in the csv db, but PostgREST caches
-- the database schema and does not reload on its own: newly parsed tables therefore
-- return PGRST205 ("Could not find the table ... in the schema cache") until a reload.
--
-- These event triggers emit `NOTIFY pgrst, 'reload schema'` on any DDL change (table
-- create/drop). PostgREST runs `LISTEN pgrst` on its connection and reloads its schema
-- cache automatically when it receives the notification.
-- Ref: https://postgrest.org/en/stable/references/schema_cache.html#schema-reloading
--
-- Idempotent: safe to run on a database where the triggers already exist.

CREATE OR REPLACE FUNCTION public.pgrst_ddl_watch() RETURNS event_trigger AS $$
BEGIN
    NOTIFY pgrst, 'reload schema';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.pgrst_drop_watch() RETURNS event_trigger AS $$
BEGIN
    NOTIFY pgrst, 'reload schema';
END;
$$ LANGUAGE plpgsql;

DROP EVENT TRIGGER IF EXISTS pgrst_ddl_watch;
CREATE EVENT TRIGGER pgrst_ddl_watch ON ddl_command_end
    EXECUTE PROCEDURE public.pgrst_ddl_watch();

DROP EVENT TRIGGER IF EXISTS pgrst_drop_watch;
CREATE EVENT TRIGGER pgrst_drop_watch ON sql_drop
    EXECUTE PROCEDURE public.pgrst_drop_watch();
