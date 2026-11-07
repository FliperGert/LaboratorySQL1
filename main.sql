CREATE TABLE spec (
    id          int PRIMARY KEY,
    table_name  VARCHAR(255) NOT NULL,
    column_name VARCHAR(255) NOT NULL,
    max_value   int          NOT NULL
);
INSERT INTO spec VALUES (1, 'spec', 'id', 1);

CREATE FUNCTION spec_track() RETURNS trigger AS $$
BEGIN
    EXECUTE format(
        'UPDATE spec
            SET max_value = GREATEST(max_value, (SELECT max(%I) FROM %I))
          WHERE table_name = %L AND column_name = %L',
        TG_ARGV[0], TG_TABLE_NAME, TG_TABLE_NAME, TG_ARGV[0]);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION next_val(tbl VARCHAR(255), col VARCHAR(255)) RETURNS int AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM spec WHERE table_name = tbl AND column_name = col) THEN
        UPDATE spec SET max_value = max_value + 1
         WHERE table_name = tbl AND column_name = col;
    ELSE
        EXECUTE format(
            'INSERT INTO spec
             SELECT next_val(''spec'', ''id''), %L, %L, COALESCE(max(%I), 0) + 1 FROM %I',
            tbl, col, col, tbl);
        EXECUTE format(
            'CREATE TRIGGER %I AFTER INSERT OR UPDATE ON %I
             FOR EACH STATEMENT EXECUTE FUNCTION spec_track(%L)',
            'trg_' || tbl || '_' || col, tbl, col);
    END IF;

    RETURN (SELECT max_value FROM spec WHERE table_name = tbl AND column_name = col);
END;
$$ LANGUAGE plpgsql;

CREATE TABLE test (id int);
INSERT INTO test VALUES (10);

SELECT next_val('test', 'id');
SELECT * FROM spec ORDER BY id;

INSERT INTO test VALUES (50);
SELECT * FROM spec ORDER BY id;

INSERT INTO test VALUES (20);
SELECT * FROM spec ORDER BY id;

UPDATE test SET id = 100 WHERE id = 50;
SELECT * FROM spec ORDER BY id;

UPDATE test SET id = 5 WHERE id = 100;
SELECT * FROM spec ORDER BY id;

SELECT next_val('test', 'id');

DROP TABLE test;
DROP FUNCTION next_val(VARCHAR, VARCHAR);
DROP FUNCTION spec_track();
DROP TABLE spec;
