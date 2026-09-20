-- Reverses 000003_cheque_request_id.up.sql.
DROP INDEX IF EXISTS pay.uq_cheques_receiver_request;
ALTER TABLE pay.cheques DROP COLUMN IF EXISTS request_id;
