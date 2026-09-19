-- Reverses 000001_init.up.sql. Every object created there lives in the
-- `pay` schema, so dropping the schema CASCADE removes every table, index,
-- and constraint in one statement instead of enumerating them in reverse
-- dependency order.
DROP SCHEMA IF EXISTS pay CASCADE;
