CREATE TABLE module_config (
    module_id TEXT PRIMARY KEY NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    settings TEXT NOT NULL CHECK (json_valid(settings))
) STRICT;
