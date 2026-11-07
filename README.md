# LaboratorySQL1
**Цель:** устранить рассогласованность спец. таблицы `spec` и отслеживаемой таблицы, когда число в ней вставлено или изменено в обход хранимой процедуры `next_val` и превышает сохранённый максимум.

**СУБД:** PostgreSQL, функции на `plpgsql`.

## Как работает решение

- Для каждой новой уникальной пары «таблица + столбец» хранимая процедура `next_val` автоматически создаёт триггер на эту таблицу. Это происходит в ветке «записи в `spec` нет», поэтому для одной пары триггер создаётся ровно один раз.
- Триггер `AFTER INSERT OR UPDATE ... FOR EACH STATEMENT` срабатывает один раз после каждого запроса `INSERT` или `UPDATE`.
- Триггерная функция `spec_track` получает имя таблицы (`TG_TABLE_NAME`) и имя столбца (`TG_ARGV[0]`) и обновляет `spec` так: `max_value = GREATEST(max_value, max(столбец))`.
- Функция `GREATEST` выбирает большее из старого максимума и текущего максимума столбца, поэтому значение в `spec` обновляется только при превышении и никогда не уменьшается.

## Ход работы

### Шаг 1. Создание спец. таблицы и начальной записи

```sql
CREATE TABLE spec (
    id          int PRIMARY KEY,
    table_name  VARCHAR(255) NOT NULL,
    column_name VARCHAR(255) NOT NULL,
    max_value   int          NOT NULL
);
INSERT INTO spec VALUES (1, 'spec', 'id', 1);
```

### Шаг 2. Создание триггерной функции

```sql
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
```

### Шаг 3. Создание ХП с автоматическим созданием триггера

```sql
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
```

## Тестирование

Подготовка: создаётся таблица `test` с одной записью.

```sql
CREATE TABLE test (id int);
INSERT INTO test VALUES (10);
```

### Тест 1. Первый вызов ХП создаёт запись и триггер

```sql
SELECT next_val('test', 'id');
SELECT * FROM spec ORDER BY id;
```

Результат: **11**. В `spec`: `(1, spec, id, 2)`, `(2, test, id, 11)`.
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/bff585a5-9bfc-4db3-869d-2324fa8d9f5b" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/d92f0aa6-0c94-4db3-89d0-09006a5c18fe" />


### Тест 2. Вставка в обход ХП, число больше максимума

```sql
INSERT INTO test VALUES (50);
SELECT * FROM spec ORDER BY id;
```

Результат: максимум вырос. В `spec`: `(2, test, id, 50)`.
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/59b5da63-55ee-44ec-a2fb-ab65df424137" />


### Тест 3. Вставка числа меньше максимума

```sql
INSERT INTO test VALUES (20);
SELECT * FROM spec ORDER BY id;
```

Результат: максимум не изменился. В `spec`: `(2, test, id, 50)`.
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/94025035-99fb-4bb3-9202-2625c8aa24b3" />


### Тест 4. Обновление до числа больше максимума

```sql
UPDATE test SET id = 100 WHERE id = 50;
SELECT * FROM spec ORDER BY id;
```

Результат: максимум вырос. В `spec`: `(2, test, id, 100)`.
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/3795d1ec-6bec-407b-adfe-9730abd81468" />


### Тест 5. Обновление до меньшего числа

```sql
UPDATE test SET id = 5 WHERE id = 100;
SELECT * FROM spec ORDER BY id;
```

Результат: максимум не уменьшился. В `spec`: `(2, test, id, 100)`.
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/ba025b7c-98d6-42a6-8915-6c236b8437b4" />


### Тест 6. ХП продолжает считать от нового максимума

```sql
SELECT next_val('test', 'id');
```

Результат: **101**.
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/1a589778-e98f-4f22-827e-d39cfc84eeaf" />


## Очистка

```sql
DROP TABLE test;
DROP FUNCTION next_val(VARCHAR, VARCHAR);
DROP FUNCTION spec_track();
DROP TABLE spec;
```

Триггер удаляется автоматически вместе с таблицей `test`.

## Вывод

Автоматически создаваемый триггер поддерживает значение в `spec` согласованным с отслеживаемой таблицей: максимум растёт при вставке и обновлении, превышающих его, и не меняется в остальных случаях. Тесты 1–6 прошли успешно, результаты совпали с ожидаемыми.
