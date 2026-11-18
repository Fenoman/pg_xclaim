# Патч сохранения кастомных ACL при обновлении `pg_xclaim` в `postgrespro-docker`

## Контекст проблемы

В `postgrespro-docker` общий цикл автообновления расширений при старте контейнера и при прокатке Ansible (`images/common/rootfs/docker-entrypoint.sh:1398-1441` и `deploy/ansible/scripts/update-extensions.sh:990-1030`) ловит любое исключение `ALTER EXTENSION <ext> UPDATE` (`WHEN OTHERS`) и для всех расширений вне списка update-only (`'pgq'`, `'pgq_coop'`) выполняет пересоздание:

```sql
_c_exec = CONCAT('DROP EXTENSION ', _c_ext.extname, ';');
EXECUTE _c_exec;

_c_exec = CONCAT('CREATE EXTENSION ', _c_ext.extname, ';');
EXECUTE _c_exec;
```

На штатном пути обновления `1.0.0-rc1 -> ... -> 1.0.0-rc5` отрабатывает `ALTER EXTENSION pg_xclaim UPDATE`, который сохраняет кастомные права `GRANT`/`REVOKE` на схеме `xclaim` и на всех сохраняемых функциях (в `1.0.0-rc4 -> 1.0.0-rc5` удаляется только выведенная тестовая функция `xclaim.debug_inject_stale(int4, int4)`). Однако при любом исключении на `ALTER EXTENSION pg_xclaim UPDATE` (например, даунгрейд образа без скрипта отката, конфликт блокировки или ошибка прав) пересоздание `DROP + CREATE`:

1. Падает на `DROP EXTENSION pg_xclaim` с `2BP01`, если поверх `xclaim.stats()` созданы пользовательские мониторинговые `VIEW`, либо при отсутствии внешних зависимостей удаляет функции расширения вместе с прикладными правами (отзыв `PUBLIC` на `session_reset()`, выдача прав прикладной роли `customer_dev`, локальные отзывы прав у именованных ролей).
2. После `CREATE EXTENSION pg_xclaim` заново исполняет дефолтные `REVOKE`/`GRANT` базового скрипта (`GRANT EXECUTE ON FUNCTION xclaim.session_reset() TO PUBLIC`, `GRANT EXECUTE ON FUNCTION xclaim.stats() TO pg_monitor`), молча снимая прикладное ужесточение прав.

## Рекомендуемая доработка в `postgrespro-docker`

### Вариант 1 (основной, для `docker-entrypoint.sh` и `update-extensions.sh`): включить `pg_xclaim` в существующий список update-only

Добавить `'pg_xclaim'` в уже существующую ветку запрета автоматического пересоздания рядом с `'pgq'` и `'pgq_coop'` в `images/common/rootfs/docker-entrypoint.sh:1415-1422` и `deploy/ansible/scripts/update-extensions.sh:1002-1009`:

```sql
        -- Очереди PgQ лежат в таблицах расширения, а на объектах pg_xclaim задаются прикладные GRANT/REVOKE.
        IF _b_error_update AND _c_ext.extname IN ('pgq', 'pgq_coop', 'pg_xclaim')
        THEN
            RAISE INFO 'Расширение % в БД: % обновляется только через ALTER EXTENSION UPDATE, пересоздание не выполняется. Старая версия: %, Новая версия: %'
                        , _c_ext.extname, CURRENT_DATABASE(), _c_ext.version_installed, _c_ext.version_avail;
            RAISE INFO 'ОШИБКА(update): %', _c_error_update;

            CONTINUE;
        END IF;
```

Это минимальная точечная правка без влияния на остальные расширения образа: при ошибке `UPDATE` пересоздание `pg_xclaim` не выполняется и кастомные ACL остаются нетронутыми.

### Вариант 2 (ручная сервисная процедура DBA при контролируемом даунгрейде)

Сценарий ниже предназначен **только для отдельного ручного запуска администратором через `psql -X -v ON_ERROR_STOP=1`** в плановом окне (не для вставки внутрь `DO`-блока `docker_update_extensions`, где `ON COMMIT DROP` и `SET LOCAL` работают в контексте внешней транзакции).

Перед `DROP EXTENSION pg_xclaim` скрипт явно проверяет отсутствие внешних объектов в `pg_depend` (пользовательские мониторинговые `VIEW` или функции поверх `xclaim.*` администратор обязан перенести или временно пересоздать осознанно по `docs/runbook.md` раздел 5.3, без слепого `CASCADE`), сохраняет снимок объектов и всех ребер ACL, выполняет отзывы один раз до многопроходного восстановления делегированных выдач (с сохранением `grantor`) и перед `COMMIT` симметрично сверяет все ребра ACL общих объектов обеих версий:

```sql
BEGIN;

-- 0. Проверка отсутствия внешних зависимостей на объекты расширения pg_xclaim (без CASCADE)
DO $$
DECLARE
    dep_list text;
BEGIN
    SELECT string_agg(pg_describe_object(d.classid, d.objid, d.objsubid), ', ' ORDER BY d.classid, d.objid)
    INTO dep_list
    FROM pg_depend d
    JOIN pg_depend de
      ON de.classid = d.refclassid
     AND de.objid = d.refobjid
     AND de.deptype = 'e'
    JOIN pg_extension e ON e.oid = de.refobjid
    WHERE e.extname = 'pg_xclaim'
      AND d.deptype IN ('n', 'a')
      AND NOT (d.classid = 'pg_extension'::regclass AND d.objid = e.oid);

    IF dep_list IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot recreate pg_xclaim while dependent objects exist (drop or recreate them explicitly first): %', dep_list;
    END IF;
END;
$$;

CREATE TEMP TABLE _pgx_saved_revokes (seq serial PRIMARY KEY, ddl text NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE _pgx_saved_grants  (seq serial PRIMARY KEY, ddl text NOT NULL) ON COMMIT DROP;

-- 1. Опись объектов и ожидаемых ребер ACL исходной версии
CREATE TEMP TABLE _pgx_pre_objs ON COMMIT DROP AS
SELECT 'schema'::text AS kind, 'xclaim'::text AS obj
FROM pg_namespace WHERE nspname = 'xclaim'
UNION ALL
SELECT 'func'::text AS kind,
       p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS obj
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'xclaim';

CREATE TEMP TABLE _pgx_expect_acl ON COMMIT DROP AS
SELECT 'schema'::text AS kind, 'xclaim'::text AS obj,
       c.grantor, c.grantee, c.privilege_type, c.is_grantable
FROM pg_namespace n,
     LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) c
WHERE n.nspname = 'xclaim'
UNION ALL
SELECT 'func'::text AS kind,
       p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS obj,
       c.grantor, c.grantee, c.privilege_type, c.is_grantable
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace,
     LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) c
WHERE n.nspname = 'xclaim';

-- 2. Отличия ACL схемы xclaim: отзывы и выдачи сверх pg_init_privs
WITH ns AS (
    SELECT n.oid,
           n.nspowner,
           coalesce(n.nspacl, acldefault('n', n.nspowner)) AS cur_acl,
           coalesce(ip.initprivs, acldefault('n', n.nspowner)) AS init_acl
    FROM pg_namespace n
    LEFT JOIN pg_init_privs ip
           ON ip.objoid = n.oid
          AND ip.classoid = 'pg_namespace'::regclass
          AND ip.objsubid = 0
    WHERE n.nspname = 'xclaim'
),
revokes AS (
    SELECT i.grantor, i.grantee, i.privilege_type, i.is_grantable,
           EXISTS (
               SELECT 1 FROM aclexplode(ns.cur_acl) c
               WHERE c.grantor = i.grantor
                 AND c.grantee = i.grantee
                 AND c.privilege_type = i.privilege_type
           ) AS still_has_base_priv
    FROM ns, aclexplode(ns.init_acl) i
    WHERE NOT EXISTS (
        SELECT 1 FROM aclexplode(ns.cur_acl) c
        WHERE c.grantor = i.grantor
          AND c.grantee = i.grantee
          AND c.privilege_type = i.privilege_type
          AND (c.is_grantable OR NOT i.is_grantable)
    )
)
INSERT INTO _pgx_saved_revokes(ddl)
SELECT format('SET LOCAL SESSION AUTHORIZATION %I; REVOKE %s%s ON SCHEMA xclaim FROM %s; RESET SESSION AUTHORIZATION;',
              gtor.rolname,
              CASE WHEN r.still_has_base_priv AND r.is_grantable THEN 'GRANT OPTION FOR ' ELSE '' END,
              r.privilege_type,
              CASE WHEN r.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(rol.rolname) END)
FROM revokes r
JOIN pg_roles gtor ON gtor.oid = r.grantor
LEFT JOIN pg_roles rol ON rol.oid = r.grantee;

WITH ns AS (
    SELECT n.oid,
           n.nspowner,
           coalesce(n.nspacl, acldefault('n', n.nspowner)) AS cur_acl,
           coalesce(ip.initprivs, acldefault('n', n.nspowner)) AS init_acl
    FROM pg_namespace n
    LEFT JOIN pg_init_privs ip
           ON ip.objoid = n.oid
          AND ip.classoid = 'pg_namespace'::regclass
          AND ip.objsubid = 0
    WHERE n.nspname = 'xclaim'
),
grants AS (
    SELECT c.grantor, c.grantee, c.privilege_type, c.is_grantable
    FROM ns, aclexplode(ns.cur_acl) c
    EXCEPT
    SELECT i.grantor, i.grantee, i.privilege_type, i.is_grantable
    FROM ns, aclexplode(ns.init_acl) i
)
INSERT INTO _pgx_saved_grants(ddl)
SELECT format('SET LOCAL SESSION AUTHORIZATION %I; GRANT %s ON SCHEMA xclaim TO %s%s; RESET SESSION AUTHORIZATION;',
              gtor.rolname,
              g.privilege_type,
              CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(rol.rolname) END,
              CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END)
FROM grants g
JOIN pg_roles gtor ON gtor.oid = g.grantor
LEFT JOIN pg_roles rol ON rol.oid = g.grantee
ORDER BY (g.grantor = (SELECT nspowner FROM pg_namespace WHERE nspname = 'xclaim')) DESC,
         g.is_grantable DESC;

-- 3. Отличия ACL функций схемы xclaim: отзывы и выдачи сверх pg_init_privs
WITH fn AS (
    SELECT p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) AS ident_args,
           p.proowner,
           coalesce(p.proacl, acldefault('f', p.proowner)) AS cur_acl,
           coalesce(ip.initprivs, acldefault('f', p.proowner)) AS init_acl
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    LEFT JOIN pg_init_privs ip
           ON ip.objoid = p.oid
          AND ip.classoid = 'pg_proc'::regclass
          AND ip.objsubid = 0
    WHERE n.nspname = 'xclaim'
),
revokes AS (
    SELECT fn.proname, fn.ident_args, i.grantor, i.grantee, i.privilege_type, i.is_grantable,
           EXISTS (
               SELECT 1 FROM aclexplode(fn.cur_acl) c
               WHERE c.grantor = i.grantor
                 AND c.grantee = i.grantee
                 AND c.privilege_type = i.privilege_type
           ) AS still_has_base_priv
    FROM fn, aclexplode(fn.init_acl) i
    WHERE NOT EXISTS (
        SELECT 1 FROM aclexplode(fn.cur_acl) c
        WHERE c.grantor = i.grantor
          AND c.grantee = i.grantee
          AND c.privilege_type = i.privilege_type
          AND (c.is_grantable OR NOT i.is_grantable)
    )
)
INSERT INTO _pgx_saved_revokes(ddl)
SELECT format('SET LOCAL SESSION AUTHORIZATION %I; REVOKE %s%s ON FUNCTION xclaim.%I(%s) FROM %s; RESET SESSION AUTHORIZATION;',
              gtor.rolname,
              CASE WHEN r.still_has_base_priv AND r.is_grantable THEN 'GRANT OPTION FOR ' ELSE '' END,
              r.privilege_type,
              r.proname,
              r.ident_args,
              CASE WHEN r.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(rol.rolname) END)
FROM revokes r
JOIN pg_roles gtor ON gtor.oid = r.grantor
LEFT JOIN pg_roles rol ON rol.oid = r.grantee;

WITH fn AS (
    SELECT p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) AS ident_args,
           p.proowner,
           coalesce(p.proacl, acldefault('f', p.proowner)) AS cur_acl,
           coalesce(ip.initprivs, acldefault('f', p.proowner)) AS init_acl
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    LEFT JOIN pg_init_privs ip
           ON ip.objoid = p.oid
          AND ip.classoid = 'pg_proc'::regclass
          AND ip.objsubid = 0
    WHERE n.nspname = 'xclaim'
),
grants AS (
    SELECT fn.proname, fn.ident_args, fn.proowner, c.grantor, c.grantee, c.privilege_type, c.is_grantable
    FROM fn, aclexplode(fn.cur_acl) c
    WHERE NOT EXISTS (
        SELECT 1 FROM aclexplode(fn.init_acl) i
        WHERE i.grantor = c.grantor
          AND i.grantee = c.grantee
          AND i.privilege_type = c.privilege_type
          AND i.is_grantable = c.is_grantable
    )
)
INSERT INTO _pgx_saved_grants(ddl)
SELECT format('SET LOCAL SESSION AUTHORIZATION %I; GRANT %s ON FUNCTION xclaim.%I(%s) TO %s%s; RESET SESSION AUTHORIZATION;',
              gtor.rolname,
              g.privilege_type,
              g.proname,
              g.ident_args,
              CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(rol.rolname) END,
              CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END)
FROM grants g
JOIN pg_roles gtor ON gtor.oid = g.grantor
LEFT JOIN pg_roles rol ON rol.oid = g.grantee
ORDER BY (g.grantor = g.proowner) DESC, g.is_grantable DESC;

DROP EXTENSION pg_xclaim;
CREATE EXTENSION pg_xclaim;

DO $$
DECLARE
    r record;
    pass int;
    mismatch_cnt int;
BEGIN
    -- Отзывы исполняются ровно один раз до выдачи делегированных грантов
    FOR r IN SELECT ddl FROM _pgx_saved_revokes ORDER BY seq LOOP
        BEGIN
            EXECUTE r.ddl;
        EXCEPTION WHEN undefined_function THEN
            NULL;
        END;
    END LOOP;

    -- Повторные проходы раскрывают цепочки делегирования owner -> A WITH GRANT OPTION -> B.
    -- Промежуточный insufficient_privilege безопасен только благодаря финальной сверке ребер ниже.
    FOR pass IN 1..4 LOOP
        FOR r IN SELECT ddl FROM _pgx_saved_grants ORDER BY seq LOOP
            BEGIN
                EXECUTE r.ddl;
            EXCEPTION WHEN undefined_function OR insufficient_privilege THEN
                NULL;
            END;
        END LOOP;
    END LOOP;

    -- Симметричная сверка по общему множеству объектов исходной и целевой версий
    WITH post_objs AS (
        SELECT 'schema'::text AS kind, 'xclaim'::text AS obj
        FROM pg_namespace WHERE nspname = 'xclaim'
        UNION ALL
        SELECT 'func'::text AS kind,
               p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS obj
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'xclaim'
    ),
    common_objs AS (
        SELECT kind, obj FROM _pgx_pre_objs
        INTERSECT
        SELECT kind, obj FROM post_objs
    ),
    cur_acl AS (
        SELECT 'schema'::text AS kind, 'xclaim'::text AS obj,
               c.grantor, c.grantee, c.privilege_type, c.is_grantable
        FROM pg_namespace n,
             LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) c
        WHERE n.nspname = 'xclaim'
        UNION ALL
        SELECT 'func'::text AS kind,
               p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS obj,
               c.grantor, c.grantee, c.privilege_type, c.is_grantable
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace,
             LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) c
        WHERE n.nspname = 'xclaim'
    ),
    expect_common AS (
        SELECT e.* FROM _pgx_expect_acl e
        JOIN common_objs co ON co.kind = e.kind AND co.obj = e.obj
    ),
    cur_common AS (
        SELECT c.* FROM cur_acl c
        JOIN common_objs co ON co.kind = c.kind AND co.obj = c.obj
    ),
    diff AS (
        (SELECT * FROM expect_common EXCEPT SELECT * FROM cur_common)
        UNION ALL
        (SELECT * FROM cur_common EXCEPT SELECT * FROM expect_common)
    )
    SELECT count(*) INTO mismatch_cnt FROM diff;

    IF mismatch_cnt > 0 THEN
        RAISE EXCEPTION 'pg_xclaim ACL verification failed (% mismatched ACL edge(s)) - rolling back', mismatch_cnt;
    END IF;
END;
$$;

COMMIT;
```
