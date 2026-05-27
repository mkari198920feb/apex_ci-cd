--liquibase formatted sql

--changeset mk:003-create-order-pkg endDelimiter:/ stripComments:false
CREATE OR REPLACE PACKAGE order_mgmt_pkg AS
    PROCEDURE create_order(
        p_customer_id   IN  NUMBER,
        p_total         IN  NUMBER,
        p_order_id      OUT NUMBER
    );

    FUNCTION get_order_status(p_order_id IN NUMBER) RETURN VARCHAR2;
END order_mgmt_pkg;
/
--rollback DROP PACKAGE order_mgmt_pkg;

--changeset mk:004-create-order-pkg-body endDelimiter:/ stripComments:false
CREATE OR REPLACE PACKAGE BODY order_mgmt_pkg AS
    PROCEDURE create_order(
        p_customer_id   IN  NUMBER,
        p_total         IN  NUMBER,
        p_order_id      OUT NUMBER
    ) IS
    BEGIN
        INSERT INTO orders (customer_id, total_amount)
        VALUES (p_customer_id, p_total)
        RETURNING order_id INTO p_order_id;
    END create_order;

    FUNCTION get_order_status(p_order_id IN NUMBER) RETURN VARCHAR2 IS
        l_status orders.status%TYPE;
    BEGIN
        SELECT status INTO l_status FROM orders WHERE order_id = p_order_id;
        RETURN l_status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN NULL;
    END get_order_status;
END order_mgmt_pkg;
/
--rollback DROP PACKAGE BODY order_mgmt_pkg;
