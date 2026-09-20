-- Tap/scan payments: the receiver's payment request carries a single-use id
-- (`x_req` in the SEP-7 URI). The sender passes it as `requestId` on
-- POST /cheques, and this index is what makes "one request, one cheque"
-- true on the server — surviving app restarts and a second device, which an
-- in-memory check on the sender's phone never could.
--
-- Scoped to the receiver: the same id from two different receivers is two
-- different requests. NULL (a plain cheque with no request) is unrestricted.
-- Refunded/terminal cheques keep their request_id on purpose: a paid-and-
-- returned request is still spent; the receiver issues a fresh one.
ALTER TABLE pay.cheques ADD COLUMN IF NOT EXISTS request_id TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cheques_receiver_request
    ON pay.cheques (receiver_address, request_id)
    WHERE request_id IS NOT NULL;
