CREATE OR REPLACE PACKAGE test_order_mgmt AS
    --%suite(Order management tests)

    --%test(create_order inserts a row and returns id)
    PROCEDURE test_create_order;

    --%test(get_order_status returns NULL for unknown id)
    PROCEDURE test_status_unknown;
END test_order_mgmt;
/

CREATE OR REPLACE PACKAGE BODY test_order_mgmt AS

    PROCEDURE test_create_order IS
        l_customer_id NUMBER;
        l_order_id    NUMBER;
        l_count       NUMBER;
    BEGIN
        INSERT INTO customers (first_name, last_name, email)
        VALUES ('Test', 'User', 'utplsql_' || dbms_random.string('x',6) || '@test.local')
        RETURNING customer_id INTO l_customer_id;

        order_mgmt_pkg.create_order(l_customer_id, 99.99, l_order_id);

        SELECT COUNT(*) INTO l_count FROM orders WHERE order_id = l_order_id;
        ut.expect(l_count).to_equal(1);

        ROLLBACK;
    END test_create_order;

    PROCEDURE test_status_unknown IS
    BEGIN
        ut.expect(order_mgmt_pkg.get_order_status(-1)).to_be_null;
    END test_status_unknown;

END test_order_mgmt;
/
