# pg_xclaim — DBA-ранбук

> **English version:** [`runbook_en.md`](runbook_en.md).

Аудитория. DBA и SRE, эксплуатирующие PostgreSQL-кластеры
(upstream PG или ABI-совместимый форк), на которых развёрнут
`pg_xclaim`.

Используйте этот ранбук, чтобы развернуть pg_xclaim, мониторить его,
реагировать на инциденты и откатываться. Документ построен по шагам:
каждую команду можно скопировать в скрипт и выполнить.

Перекрёстные ссылки в этом документе:

- `docs/incident-decision-tree.md` (оперативный разбор инцидента на дежурстве)

---

## Оглавление

1. [Чеклист перед развёртыванием](#1-чеклист-перед-развёртыванием)
2. [Этапы деплоя](#2-этапы-деплоя)
3. [Метрики мониторинга и пороги алертов](#3-метрики-мониторинга-и-пороги-алертов)
4. [Аварийный выключатель (реакция на инцидент)](#4-аварийный-выключатель-реакция-на-инцидент)
5. [Три уровня отката](#5-три-уровня-отката)
6. [Интеграция с пулером](#6-интеграция-с-пулером)
7. [Гайд по тюнингу GUC](#7-гайд-по-тюнингу-guc)
8. [Запросы для пост-миграционной валидации](#8-запросы-для-пост-миграционной-валидации)
9. [Планирование ёмкости](#9-планирование-ёмкости)
10. [Типичные ошибки и их устранение](#10-типичные-ошибки-и-их-устранение)

---

## 1. Чеклист перед развёртыванием

Не редактируйте production `postgresql.conf`, пока все шаги из
таблицы ниже не прошли. Это защита от частичной выкатки.

| # | Шаг | Команда | Критерий прохождения |
|---|------|---------|----------------------|
| 1 | Smoke gate | `bash scripts/smoke_gate.sh /path/to/pg_config` | exit 0, "SMOKE GATE PASS" |
| 2 | Smoke gate (без preload) | `bash scripts/smoke_gate_no_preload.sh /path/to/pg_config` | exit 0, SQLSTATE 55000 совпал |
| 3 | Regress matrix | `bash scripts/run_regress_matrix.sh` | все targets зелёные |
| 4 | Bench-budgets | `bash scripts/bench_try_many.sh` | оба бюджета PASS |
| 5 | Baseline `LockManager` p99 | 3-дневный capture через `pg_wait_sampling` | закоммичен в `docs/perf/baseline-pre-migration-YYYY-MM-DD.csv` |

> Все shell-сниппеты в этом ранбуке подразумевают `set -euo pipefail`.
> При копировании в скрипт добавьте эту строку в начало.

> Локаль: каждый вызов `initdb` в этом документе использует
> `--locale=ru_RU.UTF-8` — согласованно с локалью кластера.

---

## 2. Этапы деплоя

Все шаги по установке расширения и переписанию мест вызова происходят
в плановом окне обслуживания.

| Этап | Действие | Ответственный | Критерий перехода к следующему                                                                                                                                                                                              |
|------|----------|---------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0 | Собрать `pg_xclaim.so` под целевой PG-major (16/17/18) на build-хосте: `make PG_CONFIG=... && sudo make PG_CONFIG=... install`. | Build | `smoke_gate.sh` exit 0 в CI (`.github/workflows/ci-pg-matrix.yml`); файлы `pg_xclaim.so`, `pg_xclaim.control` и `pg_xclaim--<version>.sql` установлены в `$(pg_config --pkglibdir)` и `$(pg_config --sharedir)/extension/`. |
| 1 | Добавить `pg_xclaim` в `shared_preload_libraries` **последним** элементом списка (PG вызывает xact-callback'и в LIFO-порядке — последний зарегистрированный отрабатывает первым) и GUC'и `pg_xclaim.*` в `postgresql.conf`. Перезапустить кластер. | DBA | сервер стартует; в логе строка `pg_xclaim: shared memory initialized (...)`; нет `FATAL` во время `_PG_init`.                                                                                                               |
| 2 | Выполнить `CREATE EXTENSION pg_xclaim;` в каждой базе, которой нужен новый SQL surface. | DBA | `SELECT * FROM xclaim.stats();` возвращает валидную строку в каждой базе; `\dx pg_xclaim` показывает установленную версию.                                                                                                  |
| 3 | На **dev-кластере**: пересобрать функции по местам вызова (заменить `pg_try_advisory_xact_lock(...)` на `xclaim.try(...)` в целевых функциях). | DBA | Пост-проверка не находит остаточных ссылок на `pg_try_advisory_xact_lock` на мигрированных путях, функциональные smoke-тесты проходят.                                                                                      |
| 4 | Обкатка на dev: оставить расширение работать на dev-кластере 1–3 дня под обычной нагрузкой (тесты разработчиков, интеграционные тесты), чтобы проявились медленные проблемы — утечки памяти, накопление stale-записей, деградация performance. | Dev | регрессий не зафиксировано.                                                                                                                                                                                                 |
| 5 | Повторить этапы 0–2 на **prod-кластере** в плановом окне обслуживания: установить бинарники, отредактировать `postgresql.conf`, перезапустить, выполнить `CREATE EXTENSION pg_xclaim;`. | DBA | сервер стартует; `xclaim.stats()` чистая в каждой базе.                                                                                                                                                                     |
| 6 | Пересобрать функции по местам вызова на prod-кластере. | DBA | `_failed=0` и пост-проверка чистая; `xclaim.stats()` чистая.                                                                                                                                                                |
| 7 | Мониторить prod 24–48 часов. | Дежурный | инцидентов нет; `capacity_errors=0`, `cleanup_misses=0`.                                                                                                                                                                    |

> **Почему именно последним?** PostgreSQL хранит зарегистрированные
> xact-callback'и в стеке: новый кладётся в голову списка, а на
> коммите PG идёт по списку с головы
> (`REL_18_STABLE:xact.c:3812-3813,3843`). То есть последний
> зарегистрированный вызывается первым.
>
> Регистрация происходит в `_PG_init` каждого расширения, и порядок
> запуска `_PG_init` совпадает с порядком в `shared_preload_libraries`
> (`process_shared_preload_libraries()` -> `load_libraries()` в
> `miscinit.c` итерирует список библиотек в порядке GUC).
> Поставив pg_xclaim последним, мы делаем так,
> чтобы его cleanup отрабатывал самым первым на коммите — до того,
> как любой сторонний callback успеет упасть с ERROR. Это снижает
> риск, что `cleanup_misses` начнёт расти из-за прерывания цепочки.
> Подробнее — в `docs/incident-decision-tree.md`, раздел P2.

### 2.0 Сборка и установка файлов расширения

```bash
set -euo pipefail
PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config   # подгоните под целевой major

make PG_CONFIG="$PG_CONFIG" -j"$(nproc)"
sudo make PG_CONFIG="$PG_CONFIG" install

# Sanity: проверить установленные пути
test -f "$($PG_CONFIG --pkglibdir)/pg_xclaim.so"
test -f "$($PG_CONFIG --sharedir)/extension/pg_xclaim.control"
test -f "$($PG_CONFIG --sharedir)/extension/pg_xclaim--1.0.0-rc1.sql"
```

Для multi-major матрицы (16/17/18) повторить последовательность
`make` + `make install` с `pg_config` каждого target'а.

### 2.1 Пересборка функций по местам вызова

Замена `pg_try_advisory_xact_lock(...)` на `xclaim.try(...)` — это
ваш собственный скрипт под структуру вашей кодовой базы. Здесь —
только принципы, которые он должен соблюдать:

> **ПРЕДУПРЕЖДЕНИЕ: миграция одного keyspace должна быть атомарной.**
> Advisory-локи и xclaim-claim'ы живут в **разных, непересекающихся
> namespace'ах**: захват ключа K через `pg_xclaim` и захват того же K
> через `pg_try_advisory_xact_lock` **не видят друг друга**. Если одни
> места вызова, работающие с одним и тем же keyspace, мигрированы на
> xclaim, а другие нет (например, из-за сбоя в continue-on-error
> прогоне), взаимное исключение для этого keyspace **молча
> ломается**: два бэкенда одновременно «держат» один ключ, каждый
> через свой механизм.
>
> Поэтому: **все места вызова, относящиеся к одному keyspace, должны
> быть мигрированы атомарно — всё или ничего.** Continue-on-error
> (`EXCEPTION WHEN OTHERS`) безопасен **только** когда упавшие функции
> не разделяют ни одного ключа с уже мигрированными. Пост-проверка
> должна верифицировать полноту миграции **на уровне keyspace**, а не
> просто «сколько функций прошло» — частично мигрированный keyspace
> хуже, чем немигрированный.

- **Один `CREATE OR REPLACE FUNCTION` на одно место вызова** — не
  объединять переписывание нескольких функций в одну транзакцию,
  иначе ошибка в одной откатит остальные.
- **Каждый блок в `BEGIN ... EXCEPTION WHEN OTHERS ... END`** —
  логировать сбой и продолжать; не давать одному кривому identifier
  сорвать всю миграцию.
- **Пост-проверка**: после прогона сканировать `pg_proc.prosrc` на
  остаточные `pg_try_advisory_xact_lock\s*\(` в путях, которые
  должны быть уже мигрированы.
- **Логи в файл** + `set -e` в bash — чтобы можно было быстро
  показать DBA «вот эти 3 функции упали, остальные ОК».

Прогонять надо во всех базах кластера, которые используют
расширение (`SELECT datname FROM pg_database WHERE datistemplate = false`),
исключая `postgres` и системные.

---

## 3. Метрики мониторинга и пороги алертов

Все метрики берутся из `xclaim.stats()` (доступ выдан `pg_monitor`).
Рекомендуемый scrape-интервал: **15с** для Prometheus / Zabbix /
pgwatch.

| Метрика | Тип | Warn | Page | Действие |
|---------|-----|------|------|----------|
| `capacity_pct` | gauge | 80% | 90% | Поднять `pg_xclaim.max_claims`; требуется restart. |
| `capacity_errors` rate | counter | -- | любое ненулевое/мин | P1: исчерпание ёмкости в режиме error — масштабировать или перейти в `enabled=off`. |
| `capacity_warnings` rate | counter | любое | -- | Исчерпание ёмкости в режиме warn — вызывающие видят ложные `false`. |
| `cleanup_misses` rate | counter | любое | -- | P2: пропуск xact-callback'а; расследовать. |
| `reaped_stale` rate | counter | -- | > 1/мин | P3: много stale-owner reap; проверить `session_reset`, `cleanup_misses`, частоту пересоздания бэкендов. |
| `conflicts` rate | counter | -- | -- | Информационная; зависит от нагрузки. |
| `disabled_calls` rate | counter | -- | -- | Должно быть 0 в steady state. Ненулевое только при `enabled=off`. |
| `total_acquires` rate | counter | -- | -- | Throughput; baseline + alert на 50% drop. |

Кроме `xclaim.stats()` есть сигнал из server log. Расширение эмитит
`LOG` (один раз на сессию), когда live-claims одного бэкенда впервые
пересекают 75% от `pg_xclaim.expected_claims_per_backend`. Это
ранний предупредительный сигнал — он срабатывает заметно раньше
любого роста хэша: сам rehash происходит, когда заполнение массива
бакетов simplehash достигает 0.9 (fillfactor). 75% даёт запас, чтобы
поднять GUC до того, как rehash случится на горячем пути. Пример
строки лога:

```
LOG:  pg_xclaim: per-backend live claims (12345) crossed 75% of
      pg_xclaim.expected_claims_per_backend (16384) -- simplehash
      will rehash on further growth
HINT:  Raise pg_xclaim.expected_claims_per_backend to your observed
       peak and restart the cluster.
```

Готовый grep-алерт для log-агрегатора:

```bash
grep -E 'pg_xclaim:.*crossed 75%.*expected_claims_per_backend' /var/log/postgresql/*.log
```

При срабатывании: посмотрите `xclaim.stats().peak_per_backend` в
ближайшем окне, поднимите GUC до фактического peak'а с запасом
×1.2 — ×1.5 и перезапустите кластер.

Дополнительная PG-side observability по wait-event'ам:

```sql
-- Распределение per-event сэмплов. Отслеживайте p99 во времени.
SELECT wait_event, count(*)
FROM pg_stat_activity
WHERE state IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC;
```

После миграции `LWLock: xclaim_partition` появится в wait-events, но
будет коротким — это нормально. `LWLock: LockManager` p99 после
миграции основных мест вызова на горячем пути должен упасть как
минимум вдвое.

### 3.1 Watermark — строка в логе

Расширение эмитит сообщение, когда `capacity_pct` впервые пересекает
один из трёх порогов: 80%, 90%, 95% (нижний порог контролируется GUC
`pg_xclaim.capacity_warn_pct`; default 80; дальнейшие предупреждения
подавлены на 60с). Пороги 80% и 90% пишутся на уровне `LOG`, порог
95% эскалируется до `WARNING`.

Жёстко заданные пороги ниже текущего `capacity_warn_pct` не
срабатывают: ladder уважает `capacity_warn_pct`, и пороги строго ниже
настроенного значения никогда не эмитятся.

Пример (лог сервера):

```
LOG:  pg_xclaim: capacity watermark crossed -- 81% (3404288 / 4194304 claims)
```

Процент в строке целочисленный (код считает целочисленную долю, без
дробной части). Это информационное сообщение. Если устойчиво > 5 минут
— запланируйте поднятие `max_claims` в следующем окне планового
обслуживания. Если повторно пересекает 95% — поднимайте дежурного.

---

## 4. Аварийный выключатель (реакция на инцидент)

Чтобы отключить pg_xclaim без перезапуска кластера:

```sql
ALTER SYSTEM SET pg_xclaim.enabled = off;
SELECT pg_reload_conf();
```

Эффекты:

- Новые вызовы `xclaim.try` всегда возвращают `true` — захват не
  происходит.
- Уже удерживаемые записи продолжают освобождаться через xact-callback
  и `before_shmem_exit` по мере завершения транзакций.
- `xclaim.stats().disabled_calls` растёт на каждый вызов — в
  мониторинге видно, что аварийный выключатель включён.

> **КРИТИЧНО.** Пока расширение отключено, **блокировки не работают**: 
> функция `xclaim.try(k)` всегда возвращает `true`, даже если ключ уже 
> занят. Любое приложение, которое полагается на блокировки для защиты
> от дубликатов (очереди, идемпотентность, выбор лидера), начнет 
> **двойную обработку данных**. Это не просто отключение защиты, 
> это прямое нарушение логики работы.
>
> Используйте `enabled = off` ТОЛЬКО в следующих случаях:
> - Клиентский трафик полностью остановлен (плановые работы).
> - Корректность работы приложения на время диагностики не является
>   приоритетом
>   (экстренная диагностика при аварии).
>
> Всегда фиксируйте это действие в тикете инцидента. Отслеживайте
> счётчик `xclaim.stats().disabled_calls` (если он растёт — выключатель
> активен) и включайте расширение обратно сразу, как только проблема
> решена.

Чтобы включить обратно:

```sql
ALTER SYSTEM SET pg_xclaim.enabled = on;
SELECT pg_reload_conf();
```

---

## 5. Три уровня отката

### 5.1 Level 1 — мягкий откат (без restart, мгновенно)

Это аварийный выключатель `pg_xclaim.enabled = off` из §4. Расширение
становится no-op для новых захватов, уже удерживаемые claim'ы
продолжают освобождаться по мере завершения транзакций. Обратимо в
любой момент.

### 5.2 Level 2 — Code rollback (без restart)

```bash
set -euo pipefail
PGHOST=...; PGPORT=...; PGUSER=postgres
DBS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -At -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")

# Шаг 1: сначала включить soft rollback
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres \
     -c "ALTER SYSTEM SET pg_xclaim.enabled = off; SELECT pg_reload_conf();"

# Шаг 2: применить откатный DDL по местам вызова (обратный к
# forward-пересборке — восстанавливает вызовы
# pg_try_advisory_xact_lock(...) в целевых функциях)
for db in $DBS; do
    echo "=== Применяем откатный DDL по местам вызова к $db ==="
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db" \
         -v ON_ERROR_STOP=1 -f /path/to/your/rollback_rewrite.sql \
         2>&1 | tee "/tmp/pg_xclaim_rollback_${db}_$(date +%Y%m%d_%H%M%S).log"
done
```

После завершения вызывающие снова используют advisory-локи.
`pg_xclaim.enabled=off` гарантирует, что параллельный захват claim'ов
не происходит до следующего деплоя.

### 5.3 Level 3 — полный откат (требуется restart)

1. Сначала применить откатный DDL по местам вызова (Level 2 выше).
2. В следующем maintenance-окне:
   1. В каждой базе с установленным расширением выполнить
      `DROP EXTENSION pg_xclaim CASCADE;`.
   2. Отредактировать `postgresql.conf` и убрать `pg_xclaim` из
      `shared_preload_libraries`.
   3. Опционально удалить строки GUC `pg_xclaim.*`.
   4. Перезапустить кластер.
3. Убедиться, что `shared_preload_libraries` больше не упоминает
   `pg_xclaim` и кластер стартует чисто. `\dx` не показывает строку
   `pg_xclaim`.
4. Опционально `sudo make PG_CONFIG=... uninstall` (или удалить файлы
   вручную из `$(pg_config --pkglibdir)` и
   `$(pg_config --sharedir)/extension/`).

---

## 6. Интеграция с пулером

Коротко: pg_xclaim работает с любым пулером без изменений конфига.

Claim'ы освобождаются автоматически на каждом COMMIT/ABORT через
xact-callback. Он срабатывает независимо от того, как завершилась
транзакция: commit, rollback, отключение клиента, idle-in-tx timeout,
FATAL-завершение бэкенда.

Пулеры в tx-режиме (`pg_doorman`, `odyssey`, `PgBouncer`) при
некорректном разрыве соединения выдают `ROLLBACK` перед
переиспользованием бэкенда. Это триггерит cleanup pg_xclaim точно
так же, как любой другой abort path.

### Не делайте так

```ini
# !!! НЕ ДОБАВЛЯЙТЕ session_reset() В server_reset_query !!!
# server_reset_query = "SELECT xclaim.session_reset()"
```

Функция `xclaim.session_reset()` — это инструмент для экстренного 
восстановления, а не штатная процедура при возврате соединения в пул.
Если прописать её в `server_reset_query` (или аналогичную настройку 
другого пулера), возникнут три проблемы:

1. **Лишние сетевые запросы при каждой передаче соединения**. На 
   нагруженном кластере это вызовет тысячи бесполезных запросов в секунду.
2. **Постоянная смена идентификатора владельца (owner_token)**. 
   Функция `session_reset()` сбрасывает текущий токен. Из-за этого
   сборщик мусора начинает считать все оставшиеся блокировки (если они 
   случайно не очистились) "осиротевшими". Постоянный принудительный
   сброс приведет к накоплению мусорных записей в общей памяти, 
   что быстро исчерпает лимит `max_claims` и замедлит работу базы.
3. **Засорение метрики `session_resets`**. Значение в `xclaim.stats()` 
   станет бесполезным, так как этот счетчик предназначен для отлова
   редких сбоев, а не для учета штатных событий пулера.

Функция `session_reset()` нужна только когда "сессия зависла в неверном 
состоянии и ее нужно спасти или завершить". При штатной работе системы 
она не требуется.

### Когда `session_reset()` всё-таки полезен

Только когда в production наблюдается
`xclaim.stats().cleanup_misses > 0` — это сигнал, что xact-callback
был как-то обойдён, и local/shared state может быть несогласован.
В этом сценарии:

1. Включите аварийный выключатель:
   `ALTER SYSTEM SET pg_xclaim.enabled = off; SELECT pg_reload_conf();`
2. Изучите лог сервера за временное окно инкремента.
3. Принудительная очистка state в подозрительных бэкендах. SQL-вызов
   `xclaim.session_reset()` влияет только на сессию, **из которой**
   он вызван — заставить его выполниться в чужом backend нельзя.
   Реальные варианты:
   - **`SELECT pg_terminate_backend(pid)`** для конкретного pid из
     `pg_stat_activity` — backend погибает, `before_shmem_exit`
     отрабатывает cleanup, local state уходит вместе с процессом.
   - **Ротация пула** (`pgbouncer -R`, `pg_doorman` reload, `odyssey`
     SIGHUP) — все physical backends умирают и создаются заново;
     глобально чистит state, когда не знаете конкретный pid.
   - `xclaim.session_reset()` из своей admin-сессии — чистит state
     только этой сессии. Полезно если admin-сессия сама накопила
     state, не для воздействия на чужие backends.
4. Заведите тикет инцидента — это не нормальная ситуация.

### Требуемая конфигурация пулера

Никакая. Просто убедитесь, что пулер при возврате бэкенда в пул
после некорректного разрыва соединения выдаёт `ROLLBACK`, а не
голый `RESET`. Это поведение по умолчанию у `pg_doorman`, `odyssey`
и `PgBouncer`.

---

## 7. Гайд по тюнингу GUC

| GUC | По умолчанию | Где выставлять | Когда менять |
|-----|--------------|----------------|--------------|
| `shared_preload_libraries` | -- | `postgresql.conf` (postmaster) | `pg_xclaim` должен быть последним в списке; требуется restart. |
| `pg_xclaim.max_claims` | 4194304 (4M) | `postgresql.conf` (postmaster) | Поднимать, если под нагрузкой наблюдается `capacity_pct > 80%`. Каждое удвоение добавляет ~360MB shared memory (см. «Планирование ёмкости»). Требуется restart. |
| `pg_xclaim.num_partitions` | 128 | `postgresql.conf` (postmaster) | Меняется редко. Увеличивать только если `LWLock: xclaim_partition` p99 доминирует среди wait-event'ов. Требуется restart. |
| `pg_xclaim.expected_claims_per_backend` | 16384 | `postgresql.conf` (postmaster) | Заранее наращивает локальный `simplehash` до этого размера, чтобы при пиковой нагрузке (например, 750k claim'ов на один бэкенд) не пришлось делать rehash на горячем пути. Расширение пишет в server log строку `crossed 75% of pg_xclaim.expected_claims_per_backend`, когда live-claims одного бэкенда впервые пересекают 75% от GUC — это сигнал поднять GUC до фактического peak'а нагрузки. **Должен быть ≤ `pg_xclaim.max_claims`**, иначе кластер не стартует (см. §10.6). Требуется restart. |
| `pg_xclaim.enabled` | on | `ALTER SYSTEM` (PGC_SUSET) | Установите в `off`, чтобы отключить захват без перезапуска кластера — это и есть аварийный выключатель. |
| `pg_xclaim.capacity_warn_pct` | 80 | `ALTER SYSTEM` | Понизить, чтобы получать более ранние warning-логи; повысить, чтобы заглушить шум. |
| `pg_xclaim.on_capacity_exhaustion` | error | `ALTER SYSTEM` (PGC_SUSET) | Переключение в `warn` — обрабатывать исчерпание как логический конфликт (срабатывает retry path вызывающего). `error` — корректный default, форсирует sizing-дисциплину. |

### 7.1 Выбор режима `on_capacity_exhaustion`

| Сценарий | Рекомендуемый режим |
|----------|---------------------|
| Нормальная работа | `error` (default) — форсирует sizing-дисциплину. |
| Спайк неизвестной природы, повторы дёшевы | `warn` — вызывающие видят `false`, срабатывает retry path. |

WARN-режим + bulk API (`xclaim.try_many`) на стороне сервера и клиента
эмитит **ровно одно detail-WARNING на первый отказанный слот и одно
summary-WARNING в конце вызова** (`N additional slot(s) hit max_claims
... per-slot WARNINGs suppressed`). Bulk на 1000 ключей при
превышении ёмкости даёт 2 строки лога, не 1000. Счётчик
`xclaim.stats().capacity_warnings` остаётся **точным** — инкрементится
на каждый отказанный слот независимо от suppression: для sizing-обзора
используйте его, а не подсчёт WARNING-строк в логе. Single-call
`xclaim.try` не затронут — каждый вызов это отдельный statement и
эмитит свой собственный WARNING.

Режима fallback-to-advisory не существует. Делегирование в
`LockAcquire(LOCKTAG_ADVISORY)` при исчерпании ёмкости небезопасно:
cleanup xclaim'а не видит такой claim, что позволило бы тот же самый
ключ заново захватить через xclaim shmem и нарушило бы взаимное
исключение (split-brain namespace между xclaim shmem и PG LockManager).

Если ожидаете спайк, безопасный путь — последовательность через
аварийный выключатель:

1. `ALTER SYSTEM SET pg_xclaim.enabled = off; SELECT pg_reload_conf();`
   — все вызовы безусловно видят `true`, захват не выполняется.
2. Применить откатный DDL по местам вызова — он вернёт
   `pg_try_advisory_xact_lock` в проверенные места вызова. Это путь
   до миграции на pg_xclaim, с которым кластер раньше работал.
3. Поднять `max_claims` в следующем окне планового обслуживания.

---

## 8. Запросы для пост-миграционной валидации

После того как forward-скрипт пересборки функций по местам вызова
прогнан (этап 3 в §2), на каждом кластере выполнить набор
валидационных запросов:

```sql
-- Pre-migration baseline (выполнить ДО миграции; заархивировать результат):
SELECT locktype, mode, granted, count(*), count(DISTINCT pid)
FROM pg_locks
GROUP BY 1, 2, 3
ORDER BY count(*) DESC;
```

```sql
-- Post-migration: количество advisory должно упасть на мигрированных путях.
SELECT count(*) FROM pg_locks WHERE locktype = 'advisory';
-- ожидается: 0 для мигрированных путей

-- Post-migration: per-backend claim count виден.
SELECT count(*) FROM xclaim.debug_snapshot();
-- ожидается: > 0 на пиковой нагрузке
-- ВНИМАНИЕ:
--   * debug_snapshot() захватывает разделяемые блокировки (SHARED)
--     на ВСЕ партиции одновременно (по умолчанию 128) на время
--     сканирования памяти. Любые новые попытки взять блокировку 
--     будут ожидать окончания этого сканирования. На высоконагруженном 
--     кластере это вызовет **заметное зависание**, которое 
--     будет тем дольше, чем больше памяти занято. 
--     Не запускайте функцию в часы пик без крайней необходимости. 
--     Для обычного мониторинга используйте `xclaim.stats()`, а 
--     `debug_snapshot()` оставьте для разбора аварий или плановых работ.
--   * Функция доступна только если `pg_xclaim.num_partitions <= 192` 
--     (из-за лимита ядра PG на максимальное число одновременных блокировок).

-- Post-migration: ёмкость + счётчики чисты.
SELECT * FROM xclaim.stats();
-- ожидается: capacity_errors = 0
--            cleanup_misses  = 0
--            capacity_pct    < 80
```

```sql
-- Семантический паритет (доля FALSE у your_lock_success_flag до vs после):
-- Замените имена таблицы/столбцов ниже на те, что используются в
-- валидационной таблице мест вызова вашего приложения.
SELECT * FROM your_validation_table WHERE your_lock_success_flag = FALSE;
-- ожидается НЕ ноль — проверьте эквивалентное распределение
-- относительно pre-migration baseline (ссылка на
-- docs/perf/baseline-pre-migration-YYYY-MM-DD.csv).
```

```sql
-- Сдвиг распределения wait-event'ов (выполнить под пиковой нагрузкой,
-- до vs после):
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state IS NOT NULL
GROUP BY 1, 2
ORDER BY 3 DESC;
-- ожидается: 'LWLock: LockManager' p99 упал >= 50%
--            'LWLock: xclaim_partition' виден, но короткий
```

Базовый замер до миграции лежит в
`docs/perf/baseline-pre-migration-YYYY-MM-DD.csv` — DBA снимает его
через `pg_wait_sampling` за 3 дня до деплоя.

---

## 9. Планирование ёмкости

Объём shared memory у `pg_xclaim` растёт линейно от `max_claims`.

| `max_claims` | Примерно shmem |
|--------------|----------------|
| 1M | ~90 MB |
| 4M (default) | ~360 MB |
| 8M | ~720 MB |
| 16M | ~1.5 GB |

Плюс per-partition LWLock overhead (`num_partitions=128` default;
~несколько KB).

Default 4M комфортно покрывает нагрузку 750k single-backend hot-path
с 5.3× запасом плюс 10–20 параллельных бэкендов, каждый удерживает
до 100k claim'ов. Поднимать до 8M–16M только если в production
наблюдается `capacity_errors > 0` или `capacity_pct > 80`.

> **Закладывайте запас из-за неравномерности хэширования.** 
> Общая память (`max_claims`) делится на равные части между всеми
> партициями. Поскольку ключи распределяются по партициям на основе
> хэша, при неравномерной нагрузке одна из партиций может заполниться
> полностью, даже если общая занятая память (`capacity_used`) еще
> далека от 100%. 
> Симптом проблемы: появляются ошибки `capacity_errors > 0` (код 53400),
> хотя счетчик `capacity_pct` показывает низкий процент заполнения.
>
> Рекомендация по настройке: **установите `max_claims` минимум на 20% 
> больше ожидаемого пикового значения (×1.2)**. Этот запас сгладит 
> естественную неравномерность распределения при обычной нагрузке. 
> Если же у вас есть явные перекосы (например, один крупный клиент
> генерирует 80% всех блокировок), запас следует увеличить в 1.5–2 раза.

Локальная память бэкенда. Удерживаемые claim'ы живут в
backend-локальном `simplehash` (memory context `xclaim local set`,
child of TopMemoryContext). Эмпирически замерено на PG 16 и PG 18
(идентично, это backend-local код):

| Удерживается claim'ов в одной транзакции | `xclaim local set` |
|------------------------------------------|--------------------|
| 0–10 000 | ~1.58 MB (pre-grown floor под default `expected_claims_per_backend=16384`) |
| 100 000 | **~6.3 MB** |
| 750 000 | **~50.3 MB** |

Эффективная стоимость на удерживаемый claim — ~63 байта (с учётом
overhead simplehash при load factor ~75%). Запись локального набора
(`XClaimLocalEntry`) занимает 48 байт после выравнивания (см.
`src/pg_xclaim_local.h`).

### 9.1 Сравнение с состоянием до миграции (high-cardinality use case)

Реалистичный сценарий: **100k claim'ов в одной транзакции, 200
параллельных бэкендов** (то, под что pg_xclaim сделан).

Замеры на PG 16 prod-сценарии (advisory с раздутым
`max_locks_per_transaction=4096` для выживания):

| Компонент | До (advisory, `max_locks=4096`) | После (pg_xclaim, `max_locks=64` default, `max_claims=4M`) | Δ |
|-----------|---------------------------------|------------------------------------------------------------|---|
| Shared LockManager | ~100 KB | ~16 KB | −84 KB |
| Shared `pg_xclaim` dynahash | 0 | ~360 MB | +360 MB |
| Local LockManager × 200 backends (LOCALLOCK hash под 100k locks) | 16.8 MB × 200 = **3.36 GB** | минимально (`max_locks=64` cap) | **−3.35 GB** |
| Local `pg_xclaim` × 200 backends | 0 | 6.3 MB × 200 = **1.26 GB** | +1.26 GB |
| **Итого** | **~3.36 GB** | **~1.62 GB** | **−1.74 GB** |

В PG 18 общая картина та же, но Shared LockManager «до миграции» был
бы ~5 MB (а не 100 KB), за счёт Fast-Path Array; на итог это влияет
слабо.

**Главное.** Экономия идёт не за счёт shared memory (pg_xclaim как
раз **добавляет** ~360 MB shmem), а за счёт **per-backend LOCALLOCK
hash**, который под high-cardinality advisory нагрузкой растёт до
~17 MB/бэкенд и съедает несколько GB суммарно. pg_xclaim переносит
этот state в собственный compact simplehash (~6 MB на 100k claims).

Под лёгкой нагрузкой (10–100 locks в транзакции) переход на
pg_xclaim **только добавит** ~360 MB shmem без видимой экономии —
эта нагрузка изначально не нуждается в pg_xclaim.

---

## 10. Типичные ошибки и их устранение

### 10.1 SQLSTATE `53400` (`ERRCODE_CONFIGURATION_LIMIT_EXCEEDED`)

```
ERROR:  pg_xclaim: max_claims (4194304) exhausted
HINT:   Increase pg_xclaim.max_claims and restart, or set
        pg_xclaim.on_capacity_exhaustion to warn.
SQLSTATE: 53400
```

Причина: `on_capacity_exhaustion=error` (default) и shared dynahash
упёрся в `max_claims`. Транзакция вызывающего откатывается.

Устранение в порядке приоритета:

1. Немедленно: `ALTER SYSTEM SET pg_xclaim.enabled = off; SELECT pg_reload_conf();`
   (аварийный выключатель, см. раздел 4 выше) — все вызовы
   безусловно получают `true`, захват пропускается.
2. ИЛИ переключить в аварийный режим `warn`:
   `ALTER SYSTEM SET pg_xclaim.on_capacity_exhaustion = warn; SELECT pg_reload_conf();`
   (возвращает false на исчерпании, срабатывает retry path
   вызывающего; одна WARNING-строка на событие).
3. Запланировать maintenance-окно для поднятия `max_claims` (требуется
   restart).

См. `docs/incident-decision-tree.md` (P1).

### 10.2 SQLSTATE `55000` (`ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE`)

```
ERROR:  pg_xclaim must be loaded via shared_preload_libraries
SQLSTATE: 55000
```

Причина: `shared_preload_libraries` не включает `pg_xclaim`, но
приложение обратилось к `xclaim.try` / другой функции расширения.
Сам `CREATE EXTENSION pg_xclaim` без preload **не ругается** — он
создаёт только SQL-обёртки. Ошибка возникает при первом
SQL-вызове расширения (срабатывает gate `XCLAIM_REQUIRE_INIT`).

Устранение:

1. Проверьте `shared_preload_libraries`: выполните
   `SHOW shared_preload_libraries;` и убедитесь, что `pg_xclaim`
   присутствует в списке.
2. Если его нет — добавьте **последним элементом** списка
   (например `citus,timescaledb,pg_xclaim`) и перезапустите кластер.
   Порядок важен: pg_xclaim должен быть последним, чтобы его
   xact-cleanup отрабатывал первым в LIFO-цепочке callback'ов.
   См. §2 «Этапы деплоя».
3. До перезапуска используйте `pg_try_advisory_xact_lock` напрямую.
   Если кластер уже прошёл этап пересборки функций по местам вызова
   (этап 3 в §2), сначала примените свой rollback-скрипт по местам
   вызова.

### 10.3 FATAL на `_PG_init` — кластер лежит

```
FATAL:  pg_xclaim compiled against PG 1700 but running on PG 1600 -- refusing load
```

Причина: `pg_xclaim.so` собран под другой PG ABI, чем runtime
сервер. Не должно происходить после CI matrix gate; если произошло —
build-хост и runtime-хост не сходятся по PG-major (например, бинарь
под PG 17 задеплоен на PG 16 кластер).

Критично — кластер лежит. См. `docs/incident-decision-tree.md` (P0).

> **Hot-standby — это НЕ критично.** Расширение чисто preload'ится на
> standby (и на primary, который всё ещё проигрывает WAL). SQL-вызовы
> возвращают `ERRCODE_FEATURE_NOT_SUPPORTED` — `pg_xclaim does not
> support hot-standby/recovery mode` (с подсказкой
> `Remove from shared_preload_libraries on standby clusters`) — пока
> узел в recovery; проверка срабатывает в момент вызова, а не на
> preload. После promotion'а (`pg_is_in_recovery() = false`) вызовы
> успешно отрабатывают без restart'а или правки конфига.
>
> Серверный HINT предлагает убрать расширение из
> `shared_preload_libraries` на standby; это необязательно — preload
> на standby безопасен, вызовы просто корректно завершаются ошибкой до
> промоушна.

Восстановление:

1. Отредактировать `postgresql.conf` на затронутом узле — убрать
   `pg_xclaim` из `shared_preload_libraries`.
2. Перезапустить — кластер поднимается без `pg_xclaim`.
3. Найти первопричину (рассинхронизация образов? непреднамеренный
   promotion standby? ABI drift в downstream PG-форке?).

### 10.4 2PC: отказ на `PRE_PREPARE`

```
ERROR:  pg_xclaim: PREPARE TRANSACTION is not allowed while pg_xclaim claims are held
HINT:   Release pg_xclaim claims (or COMMIT/ROLLBACK the transaction) before preparing.
SQLSTATE: 0A000  -- feature_not_supported
```

Причина: приложение попыталось `PREPARE TRANSACTION` после захвата
xclaim claim'ов. xclaim явно отказывает в 2PC на
`XACT_EVENT_PRE_PREPARE`.

Это жёсткое ограничение, и оно не параллель к собственному
поведению PostgreSQL: PG core advisory xact locks **обрабатываются**
через `PREPARE TRANSACTION` посредством `AtPrepare_Locks()` (см.
PG18 `lock.c:3446`, PG17 `lock.c:3304`, PG16 `lock.c:3299`),
который записывает их в prepared GID, чтобы
последующий `COMMIT/ROLLBACK PREPARED` их освободил.

pg_xclaim отказывает в событии, потому что в PostgreSQL нет
публичного API, через который расширение могло бы стать участником
2PC. Внутренний API `RegisterTwoPhaseRecord` использует фиксированный
enum `TwoPhaseRmgrId` (см. `include/access/twophase_rmgr.h`), и
расширения в этот enum добавиться не могут.

Поддержка 2PC требует апстрим-патча в самом PostgreSQL. В текущей
модели любой `PREPARE TRANSACTION` после xclaim-acquire — это
ошибка.

Устранение: рефакторить приложение так, чтобы оно НЕ использовало
`PREPARE TRANSACTION` для транзакций, удерживающих xclaim claim'ы.
Со стороны DBA фикса нет.

**Граничный случай.** `PREPARE TRANSACTION` после `cleanup_misses`.

Отказ на `PRE_PREPARE` срабатывает только когда у бэкенда
действительно есть локально удерживаемые claim'ы
(`xclaim_local_count() > 0`).

Возможна редкая ситуация, когда у бэкенда **локальный набор пуст**,
но в shared memory остались **«осиротевшие» строки** от предыдущей
транзакции этого же бэкенда. Это происходит, если xact-callback был
пропущен (см. 10.5) — например, callback другого расширения раньше
нашего бросил ERROR. Локальное состояние при этом затирается, но
shared rows остаются.

Если в такой ситуации бэкенд делает `PREPARE TRANSACTION`,
PRE_PREPARE-проверка пропускает его (locally claims = 0), а
осиротевшие строки оператор не видит как ошибку. Это **не повреждение
данных**: токены в осиротевших строках не совпадают с текущим
токеном бэкенда, поэтому их подберёт stale-owner reaper при первом
же конфликтующем захвате (любым бэкендом).

Что делать: если в одной сессии вы видите `cleanup_misses > 0` **и**
собираетесь сделать `PREPARE TRANSACTION` — сначала вызовите
`SELECT xclaim.session_reset()`. Это ротирует owner_token и заставит
reaper подобрать осиротевшие строки на ближайшем захвате.

### 10.5 `cleanup_misses` ненулевое

Причина: xact-callback был пропущен на каком-то пути. Например,
из-за callback другого расширения, который раньше нашего бросил
ERROR в xact-end (см. секцию 2 о порядке загрузки в
`shared_preload_libraries`). Это тот симптом, под который
`xclaim.session_reset()` полезен как реактивный инструмент
аварийного восстановления состояния (см. раздел 6).

Устранение:

1. Проинспектировать лог сервера на связанные ошибки около времени
   инкремента.
2. Точечная или массовая очистка stale state. `xclaim.session_reset()`
   — backend-local функция, она работает только в сессии вызова, а
   не «через» подозрительные backends. Чтобы реально очистить чужой
   backend используйте либо `SELECT pg_terminate_backend(pid)` (точечно
   по pid из `pg_stat_activity`), либо ротацию пула соединений
   (`pgbouncer -R` / `pg_doorman` reload / `odyssey` SIGHUP) — все
   physical backends умирают и создаются заново.
3. Если ситуация устойчивая — переключите `pg_xclaim.enabled = off`,
   примените откатный DDL по местам вызова и заведите issue.

### 10.6 FATAL: `expected_claims_per_backend` > `max_claims`

```
FATAL:  pg_xclaim.expected_claims_per_backend (N) must be <= pg_xclaim.max_claims (M)
```

Причина: в `postgresql.conf` задан
`pg_xclaim.expected_claims_per_backend` больше, чем
`pg_xclaim.max_claims`. Per-backend локальный `simplehash` не может
быть больше общей shmem-ёмкости, и расширение отказывается
стартовать.

Типичный сценарий: DBA снижает `max_claims` для теста или после
ребалансировки кластера, забыв симметрично понизить
`expected_claims_per_backend` (default 16384).

Восстановление:

1. Понизить `pg_xclaim.expected_claims_per_backend` до значения ≤
   `pg_xclaim.max_claims` в `postgresql.conf`.
2. Запустить кластер заново.

### 10.7 Счётчик `reaped_stale` растёт быстрее обычного

Причина: shared-записи переживают владельца или его owner_token —
например, после `session_reset`, пропущенного cleanup callback или
быстрого recycle PGPROC-слота. Обычный hard kill backend'а (`SIGKILL`,
segfault, OOM kill) PostgreSQL обрабатывает как child crash: postmaster
завершает остальные процессы и пересоздаёт shared memory
(`REL_18_STABLE:postmaster.c:2768-2792,3180-3202`), поэтому такие события не должны
оставлять xclaim-записи для lazy-reaper'а.

Устранение:

1. Проверьте, кто вызывает `xclaim.session_reset()` и не растёт ли
   одновременно `cleanup_misses`.
2. Проверьте, как часто пулер пересоздаёт бэкенды. Быстрая ротация PGPROC-слотов
   повышает шанс stale-owner reap после callback skip.
3. Если скорость < 1/мин — это нормальное самовосстановление,
   действий не требуется.

---

Конец ранбука. Пути эскалации инцидентов — см.
`docs/incident-decision-tree.md`.
