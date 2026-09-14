-- Runs once, on first initialisation of an empty data directory.
-- n8n needs its schema to exist before it starts; it will not create it.
CREATE SCHEMA IF NOT EXISTS n8n;
