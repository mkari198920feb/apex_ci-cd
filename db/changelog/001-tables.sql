--liquibase formatted sql

--changeset mk:001-create-customers
CREATE TABLE customers (
    customer_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name    VARCHAR2(100) NOT NULL,
    last_name     VARCHAR2(100) NOT NULL,
    email         VARCHAR2(255) NOT NULL UNIQUE,
    created_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE INDEX idx_customers_email ON customers(email);
--rollback DROP TABLE customers;

--changeset mk:002-create-orders
CREATE TABLE orders (
    order_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   NUMBER NOT NULL REFERENCES customers(customer_id),
    order_date    DATE DEFAULT SYSDATE NOT NULL,
    total_amount  NUMBER(12,2) NOT NULL,
    status        VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    CONSTRAINT chk_order_status CHECK (status IN ('PENDING','PAID','SHIPPED','CANCELLED'))
);

CREATE INDEX idx_orders_customer ON orders(customer_id);
--rollback DROP TABLE orders;
