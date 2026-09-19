-- Reverses 000002_pool_deposit_at.up.sql.
ALTER TABLE pay.pool_deposits DROP COLUMN IF EXISTS last_deposit_at;
