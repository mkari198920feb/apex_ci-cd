--liquibase formatted sql

--changeset mk:005-seed-reference-data context:stage,prod
INSERT INTO customers (first_name, last_name, email)
SELECT 'Test', 'Account', 'test@example.com' FROM dual
WHERE NOT EXISTS (SELECT 1 FROM customers WHERE email = 'test@example.com');

COMMIT;
--rollback DELETE FROM customers WHERE email = 'test@example.com';
