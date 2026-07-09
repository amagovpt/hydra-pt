-- Create the resources_exceptions table in the CSV database.
--
-- The application reads/writes this table exclusively through the "csv" connection
-- pool (see udata_hydra/db/resource_exception.py: context.pool("csv")), so it must
-- live in the CSV db. Historically it was created in the main db
-- (main/20240827_add_resources_exceptions_table.sql) and moved to the csv db by hand
-- (see the no-op main/csv 20250610_migrate_resources_exception.sql, which documents the
-- manual `pg_dump | psql` step). That manual step is NOT reproduced by a clean
-- `drop_dbs` + `migrate`, which left the table missing in csv and made every
-- analyse_resource crash with UndefinedTableError. This migration recreates it so the
-- reset is reproducible.
--
-- NB: unlike the main-db version there is NO foreign key to catalog(resource_id):
-- the catalog table lives in the main db, not in the csv db.

CREATE TABLE IF NOT EXISTS resources_exceptions (
    id SERIAL PRIMARY KEY,
    resource_id UUID UNIQUE NOT NULL,
    table_indexes JSONB DEFAULT '{}'::JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    comment VARCHAR(255)
);
