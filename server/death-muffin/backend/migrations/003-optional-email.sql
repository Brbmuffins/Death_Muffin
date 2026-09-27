-- Death Muffin — make account email optional (friends-only signup, no email required).
--
-- accounts.email was NOT NULL with a UNIQUE index. Making it nullable lets /register store NULL
-- when no email is given; MySQL's UNIQUE indexes permit any number of NULLs, so the uniqueness
-- guarantee still holds for accounts that DO supply an email.
--
-- Additive and reversible: existing rows keep their values, the UNIQUE key is untouched, and no
-- data is rewritten. Safe to run once against the live death_muffin database.
-- Reverse (only works if no NULL emails exist yet):
--   ALTER TABLE accounts MODIFY COLUMN email VARCHAR(255) NOT NULL;

ALTER TABLE accounts MODIFY COLUMN email VARCHAR(255) NULL;
