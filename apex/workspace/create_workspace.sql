-- Creates the APEX workspace if it doesn't already exist.
-- Run as ADMIN / internal account, not as the workspace schema.

DECLARE
    l_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO l_count
    FROM apex_workspaces
    WHERE workspace = 'MY_WORKSPACE';

    IF l_count = 0 THEN
        apex_instance_admin.add_workspace(
            p_workspace_id   => 100100,
            p_workspace      => 'MY_WORKSPACE',
            p_primary_schema => 'MY_WORKSPACE'
        );
        DBMS_OUTPUT.PUT_LINE('Workspace MY_WORKSPACE created');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Workspace MY_WORKSPACE already exists');
    END IF;
END;
/
