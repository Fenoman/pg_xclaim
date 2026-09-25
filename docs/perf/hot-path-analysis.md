# Анализ горячего пути

> **English version:** [`hot-path-analysis_en.md`](hot-path-analysis_en.md).

Где `pg_xclaim` тратит CPU и почему. Документ для всех любопытных,
кто хочет увидеть из чего складывается overhead - без необходимости
поднимать свой профилирующий пайплайн.

Все цифры ниже - реальные измерения, снятые через `perf` и
flamegraph'ы. Артефакты лежат в `docs/perf/flamegraphs/` (SVG,
открываются в любом браузере).

Цифры зависят от железа: CPU, ядро, компилятор, наличие debug-info.
На вашем сервере будут другие. Используйте их как иллюстрацию
паттерна, а не как универсальные performance-claim'ы. Скрипт для
воспроизведения - ниже в §"Воспроизведение".

---

## Параметры профайла

| Свойство | Значение |
|----------|----------|
| Железо | x86_64 AMD EPYC, 16 vCPU @ 2.6 GHz, 62 GiB RAM (выделенный Linux VPS) |
| Ядро | 6.8.0-106-generic (Ubuntu 24.04.4 LTS) |
| PostgreSQL | **17.10 из PGDG apt repo** (`postgresql-17` + `postgresql-17-dbgsym`). Бинарник `/usr/lib/postgresql/17/bin/postgres` сам по себе stripped, но debug-info в `/usr/lib/debug/.build-id/...` подключается `perf`'ом автоматически по Build-ID. Никакой ручной пересборки PG из исходников не требуется. |
| Сборка | gcc 13.3 (`/usr/bin/gcc`), pg_xclaim собран с `PG_CFLAGS='-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer'`. `pg_xclaim.so` содержит debug-info inline (`with debug_info, not stripped`). |
| Профайлер | `perf record -F 997 -g -a` (system-wide CPU sampling), perf 6.8.12 |
| Окно | 12 секунд на single-backend сценарий, 15 секунд на concurrent. Нагрузка конечна: через секунду после старта `perf` драйвер один раз выполняет SQL сценария и не подгоняет его под окно. Если SQL заканчивается до конца окна, хвост окна проходит без нагрузки, а если не успевает - остаток в запись не попадает |
| Stack unwind | Frame pointers: `perf record -g` без `--call-graph dwarf`. У функции без frame pointer непосредственный вызывающий из стека пропадает: в scalar SVG `hash_bytes` висит под `xclaim_try_pair`, хотя вызов идет из `xclaim_try_internal` |
| Резолвинг символов | **Каждый слой резолвится своим источником:** kernel-символы - через `kallsyms`, PG core - через dbgsym Build-ID debug-info (`/usr/lib/debug/.build-id/...`), pg_xclaim - через собственный inline DWARF в `pg_xclaim.so`. Top-15 leaf-фреймов ниже именуют реальные функции (`xclaim_local_lookup_with_hash`, `hash_search_with_hash_value`, `clear_page_rep`, `asm_exc_page_fault`). Bucket `[libc.so.6]` (~2-5%) - libc memcpy/memset/strlen без `libc6-dbg`, не критично для интерпретации user-space hot-path. Требуется `sysctl kernel.kptr_restrict=0` и запуск `perf record` от root (initdb/pg_ctl/psql остаются от postgres user через `runuser`). Без этого kernel symbols схлопываются в `[unknown]` bucket. |

---

## Архитектурная цепочка вызовов

Типичный `xclaim.try(int4, int4)` в одном бэкенде:

```
PostgresMain
└── exec_simple_query
    └── PortalRun -> ExecutorRun
        └── ExecResult -> ExecEvalFuncArgs
            └── FunctionCall (V1 trampoline)
                ├── xclaim_try_pair             [SQL entry]
                │   ├── XCLAIM_REQUIRE_INIT     [recovery + preload gate]
                │   ├── memset(&key, 0, sizeof(XClaimKey))   [HASH_BLOBS req]
                │   └── xclaim_try_internal     [алгоритм из 12 шагов]
                │       ├── xclaim_ensure_owner_token        [lazy, один раз на бэкенд]
                │       ├── xclaim_compute_hash             [один hash ключа для local и shared]
                │       │   └── get_hash_value -> tag_hash -> hash_bytes
                │       ├── xclaim_local_lookup_with_hash    [быстрый путь повторного входа]
                │       │   └── xcl_local_lookup_hash (simplehash, hash передан, не пересчитывается)
                │       │       └── memcmp (16-байтный ключ)
                │       ├── xclaim_partition_lock           [hashvalue & mask]
                │       ├── LWLockAcquire(plock, EXCLUSIVE) ─┐
                │       ├── hash_search_with_hash_value     │ critical
                │       │   (HASH_ENTER_NULL - комбини-     │ section
                │       │    рованный lookup-or-insert,     │
                │       │    *found различает existing      │
                │       │    vs fresh, NULL при             │
                │       │    capacity exhaustion)           │
                │       ├── [при found && !matches_self]    │
                │       │       xclaim_is_stale_owner       │
                │       │   └── xclaim_get_pgproc_by_procno │
                │       │       └── GetPGProcByNumber       [PG core macro,
                │       │                                    storage/proc.h]
                │       ├── populate XClaimEntry owner      │
                │       │   triple (procno+lxid+token)      │ - пишет fresh
                │       │                                   │   slot ИЛИ
                │       │                                   │   перезаписывает
                │       │                                   │   stale-reap'd
                │       │                                   │   slot in place
                │       ├── PG_TRY {                        │
                │       │   xclaim_local_insert_held }      │
                │       └── LWLockRelease(plock)            ─┘
                │       ├── pg_atomic_fetch_add_u64(live_capacity)
                │       ├── pg_atomic_fetch_add_u64(per-backend total_acquires_local)
                │       └── xclaim_check_capacity_watermark
                │           └── pg_atomic_read_u64(live_capacity)
```

Очистка на COMMIT/ABORT:

```
CommitTransactionCommand / AbortTransaction
└── CallXactCallbacks(XACT_EVENT_COMMIT | _ABORT)
    └── xclaim_xact_callback
        └── xclaim_local_cleanup_held
            ├── xclaim_local_gather_pointers     [O(N) walk simplehash]
            ├── counting sort by partition_id    [O(N + num_partitions)]
            └── для каждой партиции (<= num_partitions циклов):
                ├── LWLockAcquire(plock, EXCLUSIVE) ─┐
                ├── для каждой записи в партиции:    │
                │   ├── hash_search HASH_FIND       │
                │   ├── xclaim_shared_matches_saved_owner
                │   │   (compare saved triple)      │
                │   └── hash_search HASH_REMOVE     │
                └── LWLockRelease(plock)            ─┘
            ├── pg_atomic_fetch_sub_u64(live_capacity, total_removed)  [batched]
            └── xcl_local_reset (in-place truncate of simplehash)
```

---

## Hardware-counter evidence (`perf stat`)

CPU attribution через FlameGraph отвечает на "где CPU горит когда процесс
ON-CPU". HW counters отвечают на **другой** вопрос: "is the code CPU-bound,
memory-bound, или branch-bound?", но только если сняты по процессу.
Здесь они сняты по всей машине, см. ниже.

Сырые данные: [`perf-stat/<scenario>.txt`](perf-stat/) от
`scripts/record_perf_evidence.sh` (system-wide
`perf stat -e cycles,instructions,cache-references,cache-misses,
LLC-load-misses,LLC-store-misses,branch-instructions,branch-misses,
page-faults,context-switches,cpu-migrations`).

| Сценарий | cycles | instructions | IPC | cache-miss% | branch-miss% | page-faults | ctx-sw |
|----------|------:|-------------:|----:|------------:|-------------:|------------:|-------:|
| scalar-acquire | 20.7G | 13.1G | **0.63** | 39.31% | 5.84% | 117K | 86K |
| bulk-try-many | 29.3G | 33.1G | 1.13 | 33.97% | 2.90% | 264K | 77K |
| cleanup-commit | 24.0G | 14.8G | **0.62** | 37.51% | 6.03% | 229K | 89K |
| concurrent-contention | 39.1G | 29.4G | 0.75 | 32.38% | 4.55% | 527K | 104K |

Эти счетчики снимает отдельный прогон того же SQL: `perf stat -a` на
все окно (в сырых файлах -
"Performance counter stats for 'system wide'"). В них входят все
процессы и ядро машины за все окно, включая хвост после конца SQL, а
события мультиплексированы (каждое считалось ~2/3 окна). Какая доля
приходится на бэкенд сценария, по этим данным не определить, поэтому
IPC, cache-miss% и branch-miss% не приписываются ни pg_xclaim, ни
отдельным путям вроде HASH_REMOVE.

Выигрыш bulk API над scalar эти счетчики тоже не измеряют. На Mac
(`docs/perf/bench-20260525-pg17.csv`) медианы на 750k ключей - 378 ms у
scalar и 288 ms у bulk, то есть ~1.3x.

`LLC-load-misses` показано как `<not supported>` - на тестовом
AMD EPYC ядре Linux perf не enumerate'ит LLC perf event.

---

## Off-CPU wait evidence (`pg_wait_sampling`)

FlameGraph видит ON-CPU samples - backend стоящий на LWLock или IO
**не виден**. `pg_wait_sampling` сэмплирует `pg_stat_activity.wait_event`
каждые 10ms, давая wait-attribution complement to FlameGraph.

Сырые данные: [`wait-events/<scenario>.csv`](wait-events/) (filter:
`event_type NOT IN ('Activity', 'Client', 'Timeout', 'Extension')` -
исключает idle background workers + клиентов в ClientRead).

| Сценарий | Top wait events (samples x 10ms each) |
|----------|---------------------------------------|
| scalar-acquire | IO:BuffileWrite 2, IO:BuffileRead 1 - незначимо |
| bulk-try-many | IO:BuffileWrite 22, IO:BuffileRead 4 - plpgsql tuplestore I/O |
| cleanup-commit | (empty - нет measurable waits) |
| **concurrent-contention** | **LWLock:xclaim_partition 11**, IO:BuffileWrite 12, IO:BuffileRead 5 |

**Главный вывод #1:** scalar / bulk / cleanup не имеют значимых waits -
single-backend пути не блокируются. Все CPU-time это on-CPU работа,
flamegraph дает полную картину.

**Главный вывод #2:** под 10-backend concurrent overlap
**видна реальная LWLock-contention** на `xclaim_partition`. 11 samples x 10ms
~ 110ms cumulative wait против capacity 10 backends x 15s = 150s - это
~0.07% wait time. Это доля от всего окна: нагрузка конечна и может
закончиться до его конца, так что от реального времени работы
бэкендов доля выше. Мало в абсолюте, но **прямое evidence** что наш
partition lock IS wait point под contention.

Какой путь ждал, wait events не различают: захват (`try_many` держит
partition lock на HASH_ENTER_NULL) и очистка на COMMIT берут локи
одного tranche, и ожидание любого из них видно как
`LWLock:xclaim_partition`. Если доля ожидания поднимется на больших
workloads (N > 16 backends), стоит рассмотреть partition-level
prefetching или finer-grained sharding.

Plpgsql tuplestore I/O (`IO:BuffileWrite/Read`) - workload artifact
от DO-block result set'а, не pg_xclaim's concern.

---

## Разбор горячего пути по сценариям

CPU shares - процент сэмплов в perf-окне (system-wide, только postgres
process). Каждый сценарий - один DO-блок, то есть одна транзакция на
бэкенд. В scalar, bulk и concurrent каждая итерация идет в подтранзакции
`BEGIN ... RAISE EXCEPTION ... EXCEPTION END`, но ее откат claim'ы не
снимает: они держатся до конца транзакции, и `xclaim_local_cleanup_held`
снимает их один раз, на COMMIT. Поэтому в scalar и bulk ключи
захватывает только первая итерация, а остальные (4 из 5 и 9 из 10)
повторно входят в уже взятые ключи через быстрый путь. В concurrent
claim'ы каждого бэкенда тоже копятся за все 5 итераций, и с каждой
итерацией растет доля ключей, уже взятых им самим или другими
бэкендами.

### Скалярный захват - 5 итераций x 750k `xclaim.try`

-> [`flamegraphs/scalar-acquire.svg`](flamegraphs/scalar-acquire.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 35.9% | `xclaim_local_lookup_with_hash` | Быстрый путь повторного входа - лукап в simplehash по уже посчитанному хешу. В 4 итерациях из 5 ключ уже взят, и вызов на этом заканчивается |
| 11.1% | `hash_search_with_hash_value` | HASH_ENTER_NULL первой итерации (один вызов покрывает lookup + insert) и HASH_FIND + HASH_REMOVE очистки на COMMIT |
|  5.0% | `ExecInterpExpr` | Интерпретатор выражений PG (диспетчер вызова функций) |
|  3.1% | `xclaim_local_cleanup_held` | Очистка на COMMIT: колбэк транзакции один раз снимает все 750k claim'ов |
|  3.0% | `[libc.so.6]` | libc symbols без debug (memcpy/memset/strlen - нужен `libc6-dbg` для резолва) |
|  2.3% | `AllocSetFree` | pfree в tuplestore и слоте executor'а (строки `generate_series`) |
|  1.8% | `AllocSetAlloc` | palloc в tuplestore и executor'е (в SVG - под `tuplestore_gettupleslot` и `heap_form_minimal_tuple`) |
|  1.8% | `ExecMakeTableFunctionResult` | Развертка `generate_series` в SRF |
|  1.8% | `generate_series_step_int4` | Шаг генератора |
|  1.7% | `xclaim_try_internal` | Self-time драйвера из 12 шагов |
|  1.5% | `BufFileWrite` | Запись tuple в tuplestore |
|  1.5% | `BufFileReadCommon` | Чтение из tuplestore (результат plpgsql DO-блока) |
|  1.4% | `writetup_heap` | Запись tuple в tuplestore |
|  1.4% | `heap_form_minimal_tuple` | Формирование tuple |
|  1.4% | `hash_bytes` | Хеш ключа, один на вызов: `xclaim_compute_hash` (`get_hash_value` -> `tag_hash` -> `hash_bytes`) в шаге 5, до лукапа в local-set |

Куда уходит время. Доминирует чистая работа xclaim: 35.9% в
`xclaim_local_lookup_with_hash` - fast-path reentrancy lookup для
каждого из 750k ключей x 5 итераций, и в 4 итерациях из 5 он находит
ключ и завершает вызов. Хеш ключа в эту функцию приходит готовым:
`xclaim_try_internal` считает его заранее (`xclaim_compute_hash`,
шаг 5), и `hash_bytes` виден в профиле отдельным leaf'ом (1.4%).
Следующая большая статья - `hash_search_with_hash_value` (11.1%).
Повторные итерации shared hash не трогают: сюда входят 750k
HASH_ENTER_NULL первой итерации и HASH_FIND + HASH_REMOVE очистки
на COMMIT.

`xclaim_local_cleanup_held` (3.1%) - единственная очистка в сценарии:
откат подтранзакции через `RAISE EXCEPTION` claim'ы не снимает, и все
750k записей снимаются одним проходом на COMMIT DO-блока.

Kernel-фреймы (`clear_page_rep`, `asm_exc_page_fault`) на scalar
сценарии не попадают в top-15: 5-итерационный цикл с одним и тем
же 750k ключевым пространством не churn'ит palloc-страницы, все
работает в re-used арене. `LWLockRelease` тоже не в top-15:
партиционная блокировка дешева и не доминирует даже под scalar API.

### Пакетный захват - 10 итераций x 750k `xclaim.try_many`

-> [`flamegraphs/bulk-try-many.svg`](flamegraphs/bulk-try-many.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 11.7% | `xclaim_local_lookup_with_hash` | Проверка повторного входа на каждый элемент по хешу, посчитанному при распаковке массива. В 9 итерациях из 10 ключ уже взят |
|  5.1% | `[libc.so.6]` | libc symbols без debug. В SVG вызывающие - в основном tuplestore (`writetup_heap`, `tuplestore_gettuple`, `readtup_heap`) и `xclaim_try_many_pair` |
|  4.7% | `hash_search_with_hash_value` | HASH_ENTER_NULL первой итерации под partition lock и HASH_FIND + HASH_REMOVE очистки на COMMIT |
|  4.0% | `ExecInterpExpr` | PG executor (выражения вокруг `unnest`/`generate_series`) |
|  3.5% | `AllocSetFree` | pfree в tuplestore и слоте executor'а |
|  2.7% | `xclaim_try_many_internal` | Self-time пакетного драйвера (между sub-вызовами) |
|  2.6% | `ExecMakeTableFunctionResult` | SRF dispatch для `unnest` результата |
|  2.6% | `BufFileReadCommon` | Чтение из tuplestore (результаты DO-блока) |
|  2.5% | `AllocSetAlloc` | palloc в tuplestore и executor'е (в SVG - под `heap_form_minimal_tuple` и `tuplestore_gettupleslot`) |
|  2.5% | `BufFileWrite` | Запись tuple в tuplestore |
|  2.3% | `clear_page_rep` | Kernel zero-fill свежих palloc-страниц (rep stosq на x86_64) |
|  2.3% | `ExecStoreMinimalTuple` | Сборка output tuple для bool[] результата |
|  2.2% | `writetup_heap` | Запись tuple в tuplestore |
|  2.2% | `AllocSetGetChunkSpace` | Lookup размера chunk'а в AllocSet (free-path вспомогалка) |
|  2.1% | `heap_form_minimal_tuple` | Формирование tuple |

Доминирующая стоимость user-space: `xclaim_local_lookup_with_hash`
(11.7%) + `hash_search_with_hash_value` (4.7%) +
`xclaim_try_many_internal` (2.7%) ~ 19% - это чистая работа
xclaim. Предсортировка по партициям (counting sort,
O(N + num_partitions)) слишком быстра, чтобы всплыть как отдельный
leaf - она амортизирована по всем per-key операциям и часть ее
работы попадает в `xclaim_try_many_internal` self-time.

`clear_page_rep` (2.3%) - kernel page-zero для свежих palloc
аллокаций. Bulk путь на каждую из 10 итераций аллоцирует большие
массивы: один только `slots` - 750k x sizeof(XClaimBulkSlot) (40 байт)
~ 29 MiB. Kernel первый раз дает zeroed pages, и это видимая часть.
Скалярный путь таких массивов на вызов не аллоцирует, поэтому там
`clear_page_rep` не в top-15.

Bulk путь vs scalar: `xclaim_local_lookup_with_hash` 11.7% vs 35.9% -
это доли двух профилей с разным набором работы, стоимость ключа они
не сравнивают. По времени сравнивает Mac-замер: 378 ms у scalar и
288 ms у bulk на 750k ключей.

### Callback очистки - одна транзакция: 50 x 50k acquire, затем COMMIT

-> [`flamegraphs/cleanup-commit.svg`](flamegraphs/cleanup-commit.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 25.9% | `hash_search_with_hash_value` | HASH_FIND + HASH_REMOVE в cleanup-цикле + HASH_ENTER_NULL во время захвата (доминирует, потому что cleanup проходит ВСЕ 2.5M записей) |
| 20.0% | `xclaim_local_lookup_with_hash` | Reentrancy lookup в acquire-фазе, по одному на каждый из 2.5M ключей. Обход local-set в cleanup идет через итератор simplehash и сюда не входит |
|  6.6% | `xclaim_local_cleanup_held` | Self-time драйвера групповой очистки по партициям (gather + sort + per-partition sweep) |
|  2.7% | `xclaim_local_insert_held` | Insert в local-set после успешного shared insert |
|  2.7% | `ExecInterpExpr` | Диспетчер выражений executor'а |
|  2.4% | `xclaim_try_many_internal` | Self-time bulk-драйвера |
|  2.1% | `[libc.so.6]` | libc symbols без debug |
|  1.9% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.6% | `hash_bytes` | Хеши фазы захвата: `xclaim_compute_hash` на каждый элемент при распаковке массива и пересчет хешей simplehash при вставке в local-set и его росте. Очистка хеш не считает |
|  1.5% | `clear_page_rep` | Kernel zero-fill свежих palloc страниц |
|  1.2% | `heap_form_minimal_tuple` | Формирование tuple |
|  1.1% | `tts_minimal_getsomeattrs` | Деформация tuple slot |
|  1.1% | `asm_exc_page_fault` | Kernel page-fault entry (assembly stub) |
|  1.1% | `tuplestore_gettuple` | Чтение tuple из tuplestore |
|  1.1% | `AllocSetFree` | palloc cleanup |

Cleanup сценарий - единственный, где `hash_search_with_hash_value`
доминирует на 25.9%. Это ожидаемо: весь сценарий - одна транзакция
без подтранзакций. 50 вызовов `try_many` по 50k новых ключей копят в
ней 2.5M claim'ов (2.5M HASH_ENTER_NULL), а cleanup callback на
COMMIT один раз проходит все 2.5M записей и на каждую вызывает
HASH_FIND и HASH_REMOVE. Counting sort + group-by-partition (см.
`xclaim_local_cleanup_held` 6.6%) удерживает количество LWLock
циклов <= `num_partitions` (128 при default), но per-key
HASH_REMOVE никуда не девается - это фундаментальная стоимость
освобождения N записей.

`xclaim_local_lookup_with_hash` (20.0%) - это только фаза захвата:
проверка повторного входа на каждый из 2.5M ключей, и все они
промахи, потому что ключи новые. Обход local-set в cleanup идет
через итератор simplehash в `xclaim_local_gather_pointers`, а не через
эту функцию: в SVG `xclaim_local_lookup_with_hash` под
`xclaim_local_cleanup_held` не встречается.

Kernel page-zero (`clear_page_rep` 1.5% + `asm_exc_page_fault`
1.1% = 2.6%) виден на cleanup сценарии: транзакция делает много
больших аллокаций, и ядро обнуляет их свежие страницы при первом
касании. Самая крупная - local-set: массив bucket'ов simplehash
создается под `pg_xclaim.expected_claims_per_backend` (в скриптах
записи профиля 1048576, это 96 MiB) и по дороге к 2.5M записей
растет вдвое, как минимум один раз. К ней добавляются рабочие
массивы каждого вызова `try_many` на его 50k ключей и массивы
указателей очистки на все 2.5M записей.
`LWLockRelease` не в top-15 - ограниченный сверху
`num_partitions=128` циклов lock/unlock дешев относительно работы
с hash и memory-mapping.

### Конкурентная нагрузка - 10 бэкендов x 5 итераций x 100k пересекающихся

-> [`flamegraphs/concurrent-contention.svg`](flamegraphs/concurrent-contention.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 14.6% | `hash_search_with_hash_value` | shared dynahash под конкурентной нагрузкой. Один HASH_ENTER_NULL покрывает FIND-or-INSERT |
|  ~4.2% | `xclaim_is_stale_owner` | **Проверка владельца при конфликте - главное отличие от single-backend!** (inclusive-ширина из опубликованного SVG.) 10 бэкендов раз за разом сталкиваются на одних и тех же ключах в overlap-pool, и проигравший каждый раз идет проверять, не висит ли запись от мертвого владельца |
|  5.6% | `xclaim_try_many_internal` | Self-time bulk-драйвера (между sub-вызовами, conflict path занимает больше CPU из-за дополнительных ветвлений) |
|  5.4% | `[libc.so.6]` | libc symbols без debug. В SVG вызывающие - путь COMMIT (`CommitTransaction`), tuplestore, `xclaim_local_init` и `xclaim_try_many_pair` |
|  4.7% | `xclaim_local_lookup_with_hash` | Reentrancy lookup на каждый из 100k x 5 итераций x 10 бэкендов = 5M обращений |
|  3.8% | `ExecInterpExpr` | PG executor (диспетчер `unnest`/`xclaim.try_many`/`random`) |
|  2.6% | `xclaim_local_cleanup_held` | Очистка на COMMIT: по разу на бэкенд, по всем claim'ам, накопленным за 5 итераций |
|  1.9% | `clear_page_rep` | Kernel page-zero свежих страниц. В SVG около половины - первое касание массива local set, который каждый бэкенд создает обнуленным (96 MiB) |
|  1.8% | `AllocSetAlloc` | palloc в tuplestore и executor'е (в SVG - под `tuplestore_gettupleslot` и `heap_form_minimal_tuple`) |
|  1.8% | `AllocSetFree` | pfree в tuplestore и слоте executor'а |
|  1.7% | `BufFileReadCommon` | Чтение из tuplestore |
|  1.6% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.5% | `ExecScan` | Скан tuplestore результата |
|  1.2% | `tuplestore_puttuple_common` | Запись tuple в tuplestore |
|  1.2% | `native_queued_spin_lock_slowpath` | **Kernel mm LRU vector lock** - `folio_lruvec_lock_irqsave`, когда свежая страница после page fault добавляется в LRU. В SVG большая часть этих кадров идет от обнуления local set, которое 10 бэкендов делают одновременно. Это spinlock ядра, не pg_xclaim LWLock. |

Под конкурентной нагрузкой с 10 бэкендами картина смещается:
`hash_search_with_hash_value` поднимается до 14.6%. Разных ключей
здесь меньше, чем в остальных сценариях: все 10 бэкендов берут их
случайно из пула 200k (`pool_size = 200000`), а scalar и bulk работают
с 750k ключей, cleanup - с 2.5M.

**`xclaim_is_stale_owner` поднимается до ~4%** (inclusive-ширина из
опубликованного flamegraph'а) - это путь lazy-reaper'а. Когда два
бэкенда race'ятся за один ключ в overlap pool, проигравший проверяет,
не висит ли запись от уже мертвого владельца
(procno -> PGPROC владельца -> проверка pid и owner_token). При high-overlap workload это
происходит часто и формирует свой leaf. **Архитектурно это значит, что
lazy-reaper тащит реальную нагрузку под конкуренцией - он не
"бесплатный fallback", а активный путь.**
Если этот процент будет расти на больших workload'ах
(N > 16, K > 200k) - стоит подумать о batched-validation или
background sweeper'е.

Kernel page-zero (`clear_page_rep` 1.9%, а `asm_exc_page_fault` ниже
top-15 floor 1.2%, поэтому отдельной строкой не показан) идет в
основном от local set: каждый из 10 бэкендов при первом вызове
создает массив bucket'ов simplehash на 2^21 x 48 байт = 96 MiB
(`expected_claims_per_backend = 1048576` в скриптах записи профиля), и
simplehash выделяет его с `MCXT_ALLOC_ZERO`. В SVG больше половины
`asm_exc_page_fault` висит под `xclaim_local_init`, остальное делят
рабочие массивы `try_many`, `hash_search_with_hash_value` и
tuplestore.

Атомарные операции (`__atomic_*`, на x86_64 это `lock add`/`cmpxchg`)
инлайнятся, своих кадров в flamegraph у них нет: их цена сидит внутри
кадров вызывающих функций, и отдельно по профилю ее не оценить.
Stat-счетчики при этом per-backend: каждый бэкенд пишет в свою ячейку
`XClaimBackendInfos[procno]`, а не в общий счетчик.

---

## Куда уходит время - по категориям

| Категория | Скаляр | Пакет | Очистка | Конкуренция | Что это |
|-----------|-------:|------:|--------:|------------:|---------|
| **Local simplehash** (`xclaim_local_lookup_with_hash`, `xclaim_local_insert_held`, `xclaim_local_cleanup_held`) | ~39% | ~12% | ~29% | ~7% | быстрый путь повторного входа + вставка в local-set + group-by-partition cleanup. Хеш ключа сюда не входит: `hash_bytes` учтен в строке shared dynahash |
| **Shared dynahash** (`hash_search_with_hash_value` + `hash_bytes`) | ~12.5% | ~5% | ~28% | ~16% | партиционированный shared hash под partition-LWLock |
| **PG executor / plpgsql** (`ExecInterpExpr`, tuplestore, SRF dispatch) | - | - | - | - | dispatch вызовов, машинерия FOR-loop, tuplestore I/O. Состав категории открытый, и ее долю из опубликованных профилей не восстановить |
| **xclaim driver self-time** (`xclaim_try_internal`, `xclaim_try_many_internal`, `xclaim_is_stale_owner`) | ~2% | ~3% | ~3% | **~10%** | self-time + stale-owner reaper (последний поднимается под конкуренцией) |
| **Memory alloc** (`AllocSetAlloc`, `AllocSetFree`, `AllocSetGetChunkSpace`) | ~4% | ~8% | ~1% | ~4% | palloc/pfree tuplestore и executor'а. Записи local-set лежат в массиве bucket'ов simplehash, отдельного palloc на запись нет |
| **Kernel page-zero + faults** (`clear_page_rep`, `asm_exc_page_fault`) | <1% | ~2% | ~3% | ~3% | first-touch zero-fill свежих palloc страниц + page-fault entry |
| **libc opaque** (`[libc.so.6]`) | ~3% | ~5% | ~2% | ~5% | memcpy/memset/strlen - нужен `libc6-dbg` для резолва |
| **Атомарные счетчики** (`__atomic_*`) | - | - | - | - | per-backend stat-слоты + live_capacity. На x86_64 это inline `lock`-prefixed insns внутри вызывающих функций: своих кадров нет, и доля в профиле не выделяется |
| **LWLock acquire/release** | не в top-15 | не в top-15 | не в top-15 | не в top-15 | циклы partition-lock'а (<= num_partitions=128). `LWLockAcquire` и `LWLockRelease` в top-15 нет, то есть каждая не больше 15-й строки таблицы сценария: 1.4% в scalar, 2.1% в bulk, 1.1% в cleanup, 1.2% в concurrent |

---

## Архитектурная валидация

Профайл подтверждает три ключевых инварианта, а п. 2 он проверить не
может:

1. **Циклы LWLock ограничены `num_partitions`, а не количеством
   записей.** `LWLockRelease` не попадает в top-15 ни в одном из
   четырех сценариев, то есть не больше 15-й строки таблицы: 1.4% в
   scalar, 2.1% в bulk, 1.1% в cleanup, 1.2% в concurrent. Это
   нижняя оценка стоимости группой очистки: 2.5M записей cleanup сценария
   проходят через <= 128 LWLock циклов (default `num_partitions`),
   а не 2.5M. Инвариант group-by-partition cleanup держится -
   подтверждено напрямую с разрешенными pg_xclaim symbols.

2. **Атомарные счетчики профиль не показывает.** `__atomic_*` (x86_64
   lock prefix) инлайнятся в вызывающие функции, их цена сидит внутри
   кадров вызывающих, и отсутствие в top-15 о ней ничего не говорит.
   Stat-счетчики per-backend (`XClaimBackendInfos[procno]`): каждый
   бэкенд пишет в свою cache line. Общие счетчики на одной cache line
   ping-pong'или бы ее между сокетами под конкурентной записью, а
   per-backend слоты устраняют это by design.

3. **`hash_search_with_hash_value` остается пропорциональной главной
   стоимостью shared-hash.** 5-27% в acquire-heavy и cleanup
   сценариях, без неожиданных collision storm'ов или длинных
   walk'ов цепочек. В сценарии cleanup ее доля растет до 25.9%
   именно потому, что cleanup проходит ВСЕ записи (2.5M HASH_REMOVE
   одной транзакции), но это базовая стоимость, не патологический
   contention pattern.

4. **Хеш ключа считается один раз на ключ, а очистка его не
   считает.** `xclaim_compute_hash` (`get_hash_value` ->
   `tag_hash` -> `hash_bytes`) вызывается до проверки повторного
   входа: в scalar пути - шагом 5 `xclaim_try_internal`, в bulk -
   при распаковке массива в
   `xclaim_try_many_solo`/`xclaim_try_many_pair`. Тот же
   `hashvalue` идет в лукап local-set, в `hash_search_with_hash_value`
   и во вставку в local-set, а очистка берет `hashvalue`, сохраненный
   в записи local-set. Кроме того, `hash_bytes` зовет сам simplehash:
   вставка пересчитывает хеши записей в занятых bucket'ах, мимо которых
   идет поиск места, а рост - хеши всех записей (`SH_STORE_HASH` не
   задан). В профиле `hash_bytes` - отдельный leaf: 1.4% в scalar,
   1.6% в cleanup, а в bulk он ниже порога top-15 (2.1%). Ни в одном
   SVG он не встречается под `xclaim_local_cleanup_held`.

---

## Bench-результаты на macOS PG 17.10 / Apple M-series

Платформа здесь - macOS dev-машина, а не Linux/x86_64 из
"Параметры профайла" выше. Так и задумано: `perf` flamegraph'ы
доступны только под Linux, а latency-бюджеты гонятся на той же
машине, где идет повседневная разработка. Числа служат для контроля
регрессий, не для прямого сравнения с Linux-профайлом.

| Нагрузка | Latency | Бюджет | Запас |
|----------|--------:|-------:|------:|
| 750k одиночный бэкенд, скалярный `xclaim.try` | 378 ms | 2000 ms | 5.3x |
| 750k пакетный `xclaim.try_many` | 288 ms | 500 ms | 1.74x |
| 50k acquire+COMMIT (групповая очистка по партициям) | <100 ms | 100 ms | gated `test/concurrency/grouped_cleanup_50k.sh` |
| 10 бэкендов x 100k непересекающихся (1M суммарно) | sub-second wall | - | без порога: `test/concurrency/stress_10x100k.sh` пишет время вместе с PASS |

`pg_locks.advisory` count = **0** для мигрированных путей - это
подтверждает, что расширение работает без записей в LockManager
на этих конкретных путях в этой синтетической нагрузке. Это свойство
расширения, а не универсальное утверждение про advisory-локи. Для
большинства нагрузок стандартный LockManager - правильный
инструмент (см. README §Альтернативы).

---

## Воспроизведение

```bash
# Linux x86_64 (Ubuntu 24.04 / PGDG):
sudo apt-get install -y postgresql-17 postgresql-server-dev-17 \
                        postgresql-17-dbgsym \
                        linux-tools-generic build-essential
sudo git clone https://github.com/brendangregg/FlameGraph /opt/FlameGraph

# Сборка pg_xclaim с frame pointers + debug info
PG=/usr/lib/postgresql/17/bin/pg_config
PG_CFLAGS="-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer" \
  make PG_CONFIG=$PG -j"$(nproc)"
sudo make PG_CONFIG=$PG install

# Записать все 4 сценария одной командой (от root, initdb/pg_ctl/psql
# делегируются в `postgres` user через `runuser`):
sudo scripts/record_flamegraphs.sh

# SVG'и появятся в docs/perf/flamegraphs/, top-15 leaves каждого
# сценария напечатается на stdout.
```

`scripts/record_flamegraphs.sh` сам выставляет
`kernel.kptr_restrict=0` и `kernel.perf_event_paranoid=-1` на время
прогона и восстанавливает исходные значения при выходе. Под капотом
делает то же, что было бы вручную через `perf record -F 997 -g -a`
на окно 12 секунд (15 для concurrent) для каждого сценария, прогон
workload через `psql -h /tmp -p <port> ...`, генерация SVG через
`/opt/FlameGraph/stackcollapse-perf.pl | flamegraph.pl`.

Опубликованные данные сняты с загруженным `pg_wait_sampling`: в SVG
есть кадры `[pg_wait_sampling.so]` и `pgws_collector_main`, а
`perf-stat/` и `wait-events/` пишет только
`scripts/record_perf_evidence.sh`. Это те же четыре сценария, но
скрипт грузит `pg_xclaim,pg_wait_sampling` (нужен пакет
`postgresql-17-pg-wait-sampling`) и гоняет каждый сценарий дважды:
первый прогон пишет SVG и wait events, второй - `perf stat`.
`record_flamegraphs.sh` грузит только `pg_xclaim` и пишет только SVG.

`postgresql-17-dbgsym` ставит debug-info в `/usr/lib/debug/.build-id/...`,
где `perf` находит файл по Build-ID автоматически. Без этого пакета все
функции PG core схлопнутся в `[postgres]` опаковый leaf, и top-15
будут информативны только по pg_xclaim symbols. Для source-level
kernel symbols дополнительно нужен `linux-image-$(uname -r)-dbgsym`
из ubuntu ddebs repo - без него kernel-фреймы имеют только имена
функций (через kallsyms), без файла/линии.

---

## Как читать SVG'и

Каждый блок в flamegraph - это функция в стеке вызовов:
- **Ширина** = процент CPU-времени (сэмплов)
- **Y-ось (вертикаль)** = глубина стека (root внизу)
- **Цвета** = только для визуального различия (без семантики при `--colors hot`)
- **Click - zoom in**, **Reset Zoom** - назад, **Search** - поиск подстроки по всем стекам

Что искать в `xclaim.try` flamegraph'ах:
- Широкие блоки `xclaim_local_lookup_with_hash` ближе к верху -> доминирует быстрый путь повторного входа (хеш приходит в функцию готовым, `hash_bytes` - отдельный блок)
- Блоки над `LWLockAcquire`/`LWLockRelease` -> горячие leaf'ы критической секции
- Блоки `[postgres]` -> PG core (executor, planner, диспетчер вызова функций)
- Все внутри ядра (`__x64_sys_*`, `do_*`, `entry_*`) -> syscalls / обработчики page-fault
