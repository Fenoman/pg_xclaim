# Анализ горячего пути

> **English version:** [`hot-path-analysis_en.md`](hot-path-analysis_en.md).

Где `pg_xclaim` тратит CPU и почему. Документ для всех любопытных,
кто хочет увидеть из чего складывается overhead — без необходимости
поднимать свой профилирующий пайплайн.

Все цифры ниже — реальные измерения, снятые через `perf` и
flamegraph'ы. Артефакты лежат в `docs/perf/flamegraphs/` (SVG,
открываются в любом браузере).

Цифры зависят от железа: CPU, ядро, компилятор, наличие debug-info.
На вашем сервере будут другие. Используйте их как иллюстрацию
паттерна, а не как универсальные performance-claim'ы. Скрипт для
воспроизведения — ниже в §«Воспроизведение».

---

## Параметры профайла

| Свойство | Значение |
|----------|----------|
| Железо | x86_64 AMD EPYC, 16 vCPU @ 2.6 GHz, 62 GiB RAM (выделенный Linux VPS) |
| Ядро | 6.8.0-106-generic (Ubuntu 24.04.4 LTS) |
| PostgreSQL | **17.10 из PGDG apt repo** (`postgresql-17` + `postgresql-17-dbgsym`). Бинарник `/usr/lib/postgresql/17/bin/postgres` сам по себе stripped, но debug-info в `/usr/lib/debug/.build-id/...` подключается `perf`'ом автоматически по Build-ID. Никакой ручной пересборки PG из исходников не требуется. |
| Сборка | gcc 13.3 (`/usr/bin/gcc`), pg_xclaim собран с `PG_CFLAGS='-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer'`. `pg_xclaim.so` содержит debug-info inline (`with debug_info, not stripped`). |
| Профайлер | `perf record -F 997 -g -a` (system-wide CPU sampling), perf 6.8.12 |
| Окно | 12 секунд на single-backend сценарий, 15 секунд на concurrent; нагрузка зацикливается, чтобы полностью покрыть окно |
| Stack unwind | DWARF + frame pointers |
| Резолвинг символов | **Каждый слой резолвится своим источником:** kernel-символы — через `kallsyms`, PG core — через dbgsym Build-ID debug-info (`/usr/lib/debug/.build-id/...`), pg_xclaim — через собственный inline DWARF в `pg_xclaim.so`. Top-15 leaf-фреймов ниже именуют реальные функции (`xclaim_local_lookup_with_hash`, `hash_search_with_hash_value`, `clear_page_rep`, `asm_exc_page_fault`). Bucket `[libc.so.6]` (~2-5%) — libc memcpy/memset/strlen без `libc6-dbg`, не критично для интерпретации user-space hot-path. Требуется `sysctl kernel.kptr_restrict=0` и запуск `perf record` от root (initdb/pg_ctl/psql остаются от postgres user через `runuser`); без этого kernel symbols схлопываются в `[unknown]` bucket. |

---

## Архитектурная цепочка вызовов

Типичный `xclaim.try(int4, int4)` в одном бэкенде:

```
PostgresMain
└── exec_simple_query
    └── PortalRun → ExecutorRun
        └── ExecResult → ExecEvalFuncArgs
            └── FunctionCall (V1 trampoline)
                ├── xclaim_try_pair             [SQL entry]
                │   ├── XCLAIM_REQUIRE_INIT     [recovery + preload gate]
                │   ├── memset(&key, 0, sizeof(XClaimKey))   [HASH_BLOBS req]
                │   └── xclaim_try_internal     [алгоритм из 12 шагов]
                │       ├── xclaim_ensure_owner_token        [lazy, один раз на бэкенд]
                │       ├── xclaim_local_lookup_with_hash    [быстрый путь повторного входа]
                │       │   └── xcl_local_lookup_hash (simplehash, hash передан, не пересчитывается)
                │       │       └── memcmp (16-байтный ключ)
                │       ├── xclaim_compute_hash             [hash для shared key]
                │       ├── xclaim_partition_lock           [hashvalue & mask]
                │       ├── LWLockAcquire(plock, EXCLUSIVE) ─┐
                │       ├── hash_search_with_hash_value     │ critical
                │       │   (HASH_ENTER_NULL — комбини-     │ section
                │       │    рованный lookup-or-insert;     │
                │       │    *found различает existing      │
                │       │    vs fresh; NULL при             │
                │       │    capacity exhaustion)           │
                │       ├── [при found && !matches_self]    │
                │       │       xclaim_is_stale_owner       │
                │       │   └── xclaim_get_pgproc_by_procno │
                │       │       └── GetPGProcByNumber       [PG core macro;
                │       │                                    storage/proc.h]
                │       ├── populate XClaimEntry owner      │
                │       │   triple (procno+lxid+token)      │ — пишет fresh
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
            └── для каждой партиции (≤ num_partitions циклов):
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

CPU attribution через FlameGraph отвечает на «где CPU горит когда процесс
ON-CPU». HW counters отвечают на **другой** вопрос: «is the code CPU-bound,
memory-bound, или branch-bound?». Это меняет направление оптимизации.

Сырые данные: [`perf-stat/<scenario>.txt`](perf-stat/) (system-wide
`perf stat -e cycles,instructions,cache-references,cache-misses,
LLC-load-misses,LLC-store-misses,branch-instructions,branch-misses,
page-faults,context-switches,cpu-migrations`).

| Сценарий | cycles | instructions | IPC | cache-miss% | branch-miss% | page-faults | ctx-sw |
|----------|------:|-------------:|----:|------------:|-------------:|------------:|-------:|
| scalar-acquire | 20.7G | 13.1G | **0.63** | 39.31% | 5.84% | 117K | 86K |
| bulk-try-many | 29.3G | 33.1G | 1.13 | 33.97% | 2.90% | 264K | 77K |
| cleanup-commit | 24.0G | 14.8G | **0.62** | 37.51% | 6.03% | 229K | 89K |
| concurrent-contention | 39.1G | 29.4G | 0.75 | 32.38% | 4.55% | 527K | 104K |

**Главный вывод: pg_xclaim memory-bound на этом hardware (AMD EPYC).**
Все 4 сценария показывают IPC < 1.13 при cache-miss rate > 32%. CPU
больше времени стоит на cache misses чем исполняет инструкции.

Что это значит для оптимизации:
- **Algorithmic micro-tweaks (loop unrolling, branchless code) дадут
  мало** — мы упираемся в память, не в ALU.
- **Cache-line layout, prefetching, working-set reduction** — вот
  правильное направление оптимизации для memory-bound hot path.
- **scalar 750k bench: 378 ms / bulk 750k: 288 ms на Mac M-series PG
  17.10.** Один cache miss на каждый dynahash bucket walk — основная
  стоимость на этом hardware. Single combined HASH_ENTER_NULL per
  acquire (вместо HASH_FIND + HASH_ENTER пары) — прямое следствие
  этого memory-bound профиля.

Bulk сценарий имеет самый высокий IPC (1.13): tight loop по 750k slots
без plpgsql harness между итерациями, branch predictor хорошо
работает (2.90% miss-rate). Это объясняет, почему bulk API даёт
~2.5× относительный выигрыш над scalar.

Cleanup сценарий имеет самый высокий branch-miss rate (6.03%):
HASH_REMOVE проходит по разнородным ключам с непредсказуемыми
chain-walk traversals. Это фундаментально сложно ускорить без
изменения dynahash API.

`LLC-load-misses` показано как `<not supported>` — на тестовом
AMD EPYC ядре Linux perf не enumerate'ит LLC perf event; общий
`cache-misses` покрывает ту же информацию для memory-pressure
анализа.

---

## Off-CPU wait evidence (`pg_wait_sampling`)

FlameGraph видит ON-CPU samples — backend стоящий на LWLock или IO
**не виден**. `pg_wait_sampling` сэмплирует `pg_stat_activity.wait_event`
каждые 10ms, давая wait-attribution complement to FlameGraph.

Сырые данные: [`wait-events/<scenario>.csv`](wait-events/) (filter:
`event_type NOT IN ('Activity', 'Client', 'Timeout', 'Extension')` —
исключает idle background workers + клиентов в ClientRead).

| Сценарий | Top wait events (samples × 10ms each) |
|----------|---------------------------------------|
| scalar-acquire | IO:BuffileWrite 2, IO:BuffileRead 1 — незначимо |
| bulk-try-many | IO:BuffileWrite 22, IO:BuffileRead 4 — plpgsql tuplestore I/O |
| cleanup-commit | (empty — нет measurable waits) |
| **concurrent-contention** | **LWLock:xclaim_partition 11**, IO:BuffileWrite 12, IO:BuffileRead 5 |

**Главный вывод #1:** scalar / bulk / cleanup не имеют значимых waits —
single-backend пути не блокируются. Все CPU-time это on-CPU работа,
flamegraph даёт полную картину.

**Главный вывод #2 (новый):** под 10-backend concurrent overlap **впервые
видна реальная LWLock-contention** на `xclaim_partition`. 11 samples × 10ms
≈ 110ms cumulative wait против capacity 10 backends × 15s = 150s — это
~0.07% wait time. Мало в абсолюте, но **первое прямое evidence** что наш
partition lock IS wait point под contention.

Это подтверждает корректность архитектурного выбора:
- group-by-partition cleanup (≤ `num_partitions=128` циклов lock/unlock)
  держит wait time уверенно ниже 0.1%, что и заявляли;
- если эта доля поднимется на бо́льших workloads (N > 16
  backends), стоит рассмотреть partition-level prefetching или
  finer-grained sharding.

Plpgsql tuplestore I/O (`IO:BuffileWrite/Read`) — workload artifact
от DO-block result set'а, не pg_xclaim's concern.

---

## Разбор горячего пути по сценариям

CPU shares — процент сэмплов в perf-окне (system-wide; только postgres
process). Нагрузки выполняются в одной внешней транзакции с
блоками подтранзакций `BEGIN ... RAISE EXCEPTION ... EXCEPTION END` на каждой итерации
для контролируемого release состояния.

### Скалярный захват — 5 итераций × 750k `xclaim.try` (через rollback подтранзакции)

→ [`flamegraphs/scalar-acquire.svg`](flamegraphs/scalar-acquire.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 35.9% | `xclaim_local_lookup_with_hash` | Быстрый путь повторного входа — лукап в simplehash; вычисление `hash_bytes` ключа inlined в эту же функцию |
| 11.1% | `hash_search_with_hash_value` | Один комбинированный HASH_ENTER_NULL под partition lock покрывает lookup + insert |
|  5.0% | `ExecInterpExpr` | Интерпретатор выражений PG (диспетчер вызова функций) |
|  3.1% | `xclaim_local_cleanup_held` | Subxact rollback caller — очистка local-set от записей, не подтверждённых subxact'ом |
|  3.0% | `[libc.so.6]` | libc symbols без debug (memcpy/memset/strlen — нужен `libc6-dbg` для резолва) |
|  2.3% | `AllocSetFree` | pfree в end-of-iteration cleanup |
|  1.8% | `AllocSetAlloc` | palloc записей local-set |
|  1.8% | `ExecMakeTableFunctionResult` | Развёртка `generate_series` в SRF |
|  1.8% | `generate_series_step_int4` | Шаг генератора |
|  1.7% | `xclaim_try_internal` | Self-time драйвера из 12 шагов |
|  1.5% | `BufFileWrite` | Запись tuple в tuplestore |
|  1.5% | `BufFileReadCommon` | Чтение из tuplestore (результат plpgsql DO-блока) |
|  1.4% | `writetup_heap` | Запись tuple в tuplestore |
|  1.4% | `heap_form_minimal_tuple` | Формирование tuple |
|  1.4% | `hash_bytes` | Standalone hash-вычисления остаются только в cleanup path; acquire paths inline хеш через `xclaim_local_lookup_with_hash` |

Куда уходит время. Доминирует чистая работа xclaim: 35.9% в
`xclaim_local_lookup_with_hash` — fast-path reentrancy lookup для
каждого из 750k ключей × 5 итераций. `hash_bytes` вычисляется
внутри этого вызова, поэтому стоит standalone `hash_bytes` фрейм
видим только в cleanup path (~1.4%).
Следующая большая статья — `hash_search_with_hash_value` (11.1%):
один HASH_ENTER_NULL под partition LWLock покрывает lookup-or-insert
для каждого ключа.

`xclaim_local_cleanup_held` (3.1%) виден здесь потому, что каждая
итерация subxact rollback'а через `RAISE EXCEPTION` инвалидирует
local-set записи и они подчищаются — это не bug, это естественное
поведение workload'а.

Kernel-фреймы (`clear_page_rep`, `asm_exc_page_fault`) на scalar
сценарии не попадают в top-15: 5-итерационный цикл с одним и тем
же 750k ключевым пространством не churn'ит palloc-страницы, всё
работает в re-used арене. `LWLockRelease` тоже не в top-15:
партиционная блокировка дёшева и не доминирует даже под scalar API.

### Пакетный захват — 10 итераций × 750k `xclaim.try_many`

→ [`flamegraphs/bulk-try-many.svg`](flamegraphs/bulk-try-many.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 11.7% | `xclaim_local_lookup_with_hash` | Проверка повторного входа на каждый элемент + inline `hash_bytes` |
|  5.1% | `[libc.so.6]` | libc symbols без debug (memcpy/memset в обвязке construct_md_array) |
|  4.7% | `hash_search_with_hash_value` | HASH_ENTER в shared dynahash под partition lock |
|  4.0% | `ExecInterpExpr` | PG executor (выражения вокруг `unnest`/`generate_series`) |
|  3.5% | `AllocSetFree` | Цепочка palloc-освобождений на батч |
|  2.7% | `xclaim_try_many_internal` | Self-time пакетного драйвера (между sub-вызовами) |
|  2.6% | `ExecMakeTableFunctionResult` | SRF dispatch для `unnest` результата |
|  2.6% | `BufFileReadCommon` | Чтение из tuplestore (результаты DO-блока) |
|  2.5% | `AllocSetAlloc` | palloc записей local-set + bulk slots массив |
|  2.5% | `BufFileWrite` | Запись tuple в tuplestore |
|  2.3% | `clear_page_rep` | Kernel zero-fill свежих palloc-страниц (rep stosq на x86_64) |
|  2.3% | `ExecStoreMinimalTuple` | Сборка output tuple для bool[] результата |
|  2.2% | `writetup_heap` | Запись tuple в tuplestore |
|  2.2% | `AllocSetGetChunkSpace` | Lookup размера chunk'а в AllocSet (free-path вспомогалка) |
|  2.1% | `heap_form_minimal_tuple` | Формирование tuple |

Доминирующая стоимость user-space: `xclaim_local_lookup_with_hash`
(11.7%) + `hash_search_with_hash_value` (4.7%) +
`xclaim_try_many_internal` (2.7%) ≈ 19% — это чистая работа
xclaim. Предсортировка по партициям (counting sort,
O(N + num_partitions)) слишком быстра, чтобы всплыть как отдельный
leaf — она амортизирована по всем per-key операциям и часть её
работы попадает в `xclaim_try_many_internal` self-time.

`clear_page_rep` (2.3%) — kernel page-zero для свежих palloc
аллокаций. Bulk путь аллоцирует большие массивы (750k slots ×
sizeof(XClaimBulkSlot) ≈ 25 MiB) на каждый из 10 итераций; kernel
первый раз даёт zeroed pages, и это видимая часть. На scalar пути
эти страницы переиспользуются между итерациями (один итеративный
buffer), поэтому там `clear_page_rep` не в top-15.

Bulk путь vs scalar: `xclaim_local_lookup_with_hash` 11.7% vs 35.9%
(в ~3.1× ниже доля) — потому что overhead PG executor / plpgsql
обвязки распределяется по 750k ключам внутри одного SQL-вызова, а
не по N итерациям plpgsql FOR-loop'а. Это именно та экономия, ради
которой bulk API существует.

### Callback очистки — 50 транзакций × 50k acquire+COMMIT

→ [`flamegraphs/cleanup-commit.svg`](flamegraphs/cleanup-commit.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 25.9% | `hash_search_with_hash_value` | HASH_REMOVE в cleanup-цикле + HASH_ENTER во время захвата (доминирует, потому что cleanup проходит ВСЕ записи) |
| 20.0% | `xclaim_local_lookup_with_hash` | Reentrancy lookup в acquire-фазе + walk по local-set в cleanup |
|  6.6% | `xclaim_local_cleanup_held` | Self-time драйвера групповой очистки по партициям (gather + sort + per-partition sweep) |
|  2.7% | `xclaim_local_insert_held` | Insert в local-set после успешного shared insert |
|  2.7% | `ExecInterpExpr` | Диспетчер выражений executor'а |
|  2.4% | `xclaim_try_many_internal` | Self-time bulk-драйвера |
|  2.1% | `[libc.so.6]` | libc symbols без debug |
|  1.9% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.6% | `hash_bytes` | Standalone hash-вычисления в cleanup path (acquire paths inline хеш в `xclaim_local_lookup_with_hash`) |
|  1.5% | `clear_page_rep` | Kernel zero-fill свежих palloc страниц |
|  1.2% | `heap_form_minimal_tuple` | Формирование tuple |
|  1.1% | `tts_minimal_getsomeattrs` | Деформация tuple slot |
|  1.1% | `asm_exc_page_fault` | Kernel page-fault entry (assembly stub) |
|  1.1% | `tuplestore_gettuple` | Чтение tuple из tuplestore |
|  1.1% | `AllocSetFree` | palloc cleanup |

Cleanup сценарий — единственный, где `hash_search_with_hash_value`
доминирует на 25.9%. Это ожидаемо: cleanup callback вызывает
HASH_REMOVE на каждую из 50k записей в транзакции × 50 транзакций =
2.5M операций dynahash. Counting sort + group-by-partition (см.
`xclaim_local_cleanup_held` 6.6%) удерживает количество LWLock
циклов ≤ `num_partitions` (128 при default), но per-key
HASH_REMOVE никуда не девается — это фундаментальная стоимость
освобождения N записей.

`xclaim_local_lookup_with_hash` (20.0%) — это и acquire fast-path
(на 50k acquire), и walk по local-set в cleanup (`gather pointers`
inlined в эту же функцию).

Kernel page-zero (`clear_page_rep` 1.5% + `asm_exc_page_fault`
1.1% = 2.6%) виден на cleanup сценарии: каждая транзакция аллоцирует
50k записей в TopMemoryContext, и часть страниц приходится первый
раз очищать. `LWLockRelease` не в top-15 — ограниченный сверху
`num_partitions=128` циклов lock/unlock дёшев относительно работы
с hash и memory-mapping.

### Конкурентная нагрузка — 10 бэкендов × 5 итераций × 100k пересекающихся

→ [`flamegraphs/concurrent-contention.svg`](flamegraphs/concurrent-contention.svg)

| % | Функция | На что уходит время |
|--:|---------|---------------------|
| 14.6% | `hash_search_with_hash_value` | shared dynahash под конкурентной нагрузкой; один HASH_ENTER_NULL покрывает FIND-or-INSERT |
|  ~4.2% | `xclaim_is_stale_owner` | **Проверка владельца при конфликте — главное отличие от single-backend!** (inclusive-ширина из опубликованного SVG.) 10 бэкендов раз за разом сталкиваются на одних и тех же ключах в overlap-pool, и проигравший каждый раз идёт проверять, не висит ли запись от мёртвого владельца |
|  5.6% | `xclaim_try_many_internal` | Self-time bulk-драйвера (между sub-вызовами; conflict path занимает больше CPU из-за дополнительных ветвлений) |
|  5.4% | `[libc.so.6]` | libc symbols (memcpy + bytecode для random()) |
|  4.7% | `xclaim_local_lookup_with_hash` | Reentrancy lookup на каждый из 100k × 5 итераций × 10 бэкендов = 5M обращений |
|  3.8% | `ExecInterpExpr` | PG executor (диспетчер `unnest`/`xclaim.try_many`/`random`) |
|  2.6% | `xclaim_local_cleanup_held` | Subxact rollback cleanup на каждой итерации |
|  1.9% | `clear_page_rep` | Kernel page-zero — palloc churn на 10 backends хуже, чем на single |
|  1.8% | `AllocSetAlloc` | palloc записей local-set |
|  1.8% | `AllocSetFree` | pfree после батча |
|  1.7% | `BufFileReadCommon` | Чтение из tuplestore |
|  1.6% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.5% | `ExecScan` | Скан tuplestore результата |
|  1.2% | `tuplestore_puttuple_common` | Запись tuple в tuplestore |
|  1.2% | `native_queued_spin_lock_slowpath` | **Kernel mm LRU vector lock** — `folio_lruvec_lock_irqsave` под heavy palloc churn от 10 backends. Это workload-induced kernel cost (random() + per-iteration palloc), не pg_xclaim LWLock. |

Под конкурентной нагрузкой с 10 бэкендами картина смещается:
`hash_search_with_hash_value` поднимается до 14.6% — потому что
каждое HASH_ENTER в shared dynahash под partition LWLock'ом теперь
конкурирует с 9 другими бэкендами, walk цепочек дольше из-за более
плотной заполненности, и часть времени уходит в spin внутри
LWLockAcquire.

**`xclaim_is_stale_owner` поднимается до ~4%** (inclusive-ширина из
опубликованного flamegraph'а) — это путь lazy-reaper'а. Когда два
бэкенда race'ятся за один ключ в overlap pool, проигравший проверяет,
не висит ли запись от уже мёртвого владельца
(procno → MyProc → live xact check). При high-overlap workload это
происходит часто и формирует свой leaf. **Архитектурно это значит, что
lazy-reaper тащит реальную нагрузку под конкуренцией — он не
«бесплатный fallback», а активный путь.**
Если этот процент будет расти на бо́льших workload'ах
(N > 16, K > 200k) — стоит подумать о batched-validation или
background sweeper'е.

Kernel page-zero (`clear_page_rep` 1.9%; `asm_exc_page_fault` ниже
top-15 floor 1.2%, поэтому отдельной строкой не показан) видна именно
здесь: 10 backends × 5 итераций × 100k ключей × random() input создают
много свежих palloc страниц, которые kernel первый раз обнуляет.

Атомарных операций (`__atomic_*`, на x86_64 это inlined
`lock add`/`cmpxchg`) в top-15 нет — то есть на shared atomic
counter'ах spend < 1.2%. Это подтверждает корректность дизайна
per-backend stat-слотов: каждый бэкенд пишет в свою ячейку
`XClaimBackendInfos[procno]`, а не в общий счётчик. На общем
счётчике 10 backends ping-pong'или бы кэш-линию между NUMA-узлами
и эта строка top-15 видела бы ~15-20% atomic-overhead.

---

## Куда уходит время — по категориям

| Категория | Скаляр | Пакет | Очистка | Конкуренция | Что это |
|-----------|-------:|------:|--------:|------------:|---------|
| **Local simplehash** (`xclaim_local_lookup_with_hash`, `xclaim_local_insert_held`, `xclaim_local_cleanup_held`) | ~37% | ~12% | ~29% | ~7% | быстрый путь повторного входа + group-by-partition cleanup; hash-калькуляция inlined в эту категорию |
| **Shared dynahash** (`hash_search_with_hash_value` + `hash_bytes`) | ~12.5% | ~5% | ~28% | ~16% | партиционированный shared hash; под partition-LWLock |
| **PG executor / plpgsql** (`ExecInterpExpr`, tuplestore, SRF dispatch) | ~12% | ~15% | ~10% | ~13% | dispatch вызовов, машинерия FOR-loop, tuplestore I/O |
| **xclaim driver self-time** (`xclaim_try_internal`, `xclaim_try_many_internal`, `xclaim_is_stale_owner`) | ~2% | ~3% | ~3% | **~10%** | self-time + stale-owner reaper (последний поднимается под конкуренцией) |
| **Memory alloc** (`AllocSetAlloc`, `AllocSetFree`, `AllocSetGetChunkSpace`) | ~4% | ~9% | ~1% | ~4% | palloc/pfree обвязка локалов и tuplestore |
| **Kernel page-zero + faults** (`clear_page_rep`, `asm_exc_page_fault`) | <1% | ~2% | ~3% | ~3% | first-touch zero-fill свежих palloc страниц + page-fault entry |
| **libc opaque** (`[libc.so.6]`) | ~3% | ~5% | ~2% | ~5% | memcpy/memset/strlen — нужен `libc6-dbg` для резолва |
| **Атомарные счётчики** (`__atomic_*`) | <1% | <1% | <1% | <1.2% | per-backend stat-слоты + live_capacity; на x86_64 inline `lock`-prefixed insns |
| **LWLock acquire/release** | <1% | <1% | <1% | <1% | циклы partition-lock'а (≤ num_partitions=128); не попадает в top-15 |

---

## Архитектурная валидация

Профайл подтверждает четыре ключевых инварианта:

1. **Циклы LWLock ограничены `num_partitions`, а не количеством
   записей.** `LWLockRelease` не попадает в top-15 ни в одном из
   четырёх сценариев (то есть <1% самплов везде). Это нижняя оценка
   стоимости группой очистки: 50k записей в cleanup сценарии
   проходят через ≤ 128 LWLock циклов (default `num_partitions`),
   а не 50k. Инвариант group-by-partition cleanup держится —
   подтверждено напрямую с разрешёнными pg_xclaim symbols.

2. **Cache-line contention минимальна.** Под 10-бэкендной
   конкурентной нагрузкой ни один из `__atomic_*` (x86_64 lock
   prefix) не попадает в top-15 (<1.3%). Это спасибо per-backend
   stat-слотам (`XClaimBackendInfos[procno]`): каждый бэкенд пишет
   в свою cache line. Общие счётчики на одной cache line
   ping-pong'или бы её между сокетами под конкурентной записью;
   per-backend слоты устраняют это by design.

3. **`hash_search_with_hash_value` остаётся пропорциональной главной
   стоимостью shared-hash.** 5–27% в acquire-heavy и cleanup
   сценариях, без неожиданных collision storm'ов или длинных
   walk'ов цепочек. В сценарии cleanup её доля растёт до 25.9%
   именно потому, что cleanup проходит ВСЕ записи (50k × 50 tx =
   2.5M HASH_REMOVE), но это базовая стоимость, не патологический
   contention pattern.

4. **Standalone `hash_bytes` фрейм виден только в cleanup path
   (≤ 1.5%).** Acquire paths (scalar + bulk) проходят hash compute
   inside `xclaim_local_lookup_with_hash` — без отдельного top-leaf
   фрейма для hash. Cleanup использует уже сохранённый hashvalue из
   local-set записи, так что hash_bytes там не вызывается; standalone
   1.5% — это переходные hash compute сайты, которые ещё не
   покрыты inlining.

---

## Bench-результаты на macOS PG 17.10 / Apple M-series

Платформа здесь — macOS dev-машина, а не Linux/x86_64 из
«Параметры профайла» выше. Так и задумано: `perf` flamegraph'ы
доступны только под Linux, а latency-бюджеты гонятся на той же
машине, где идёт повседневная разработка. Числа служат для контроля
регрессий, не для прямого сравнения с Linux-профайлом.

| Нагрузка | Latency | Бюджет | Запас |
|----------|--------:|-------:|------:|
| 750k одиночный бэкенд, скалярный `xclaim.try` | 378 ms | 2000 ms | 5.3× |
| 750k пакетный `xclaim.try_many` | 288 ms | 500 ms | 1.74× |
| 50k acquire+COMMIT (групповая очистка по партициям) | <100 ms | 100 ms | gated `test/concurrency/grouped_cleanup_50k.sh` |
| 10 бэкендов × 100k пересекающихся (1M суммарно) | sub-second wall | — | gated `test/concurrency/stress_10x100k.sh` |

`pg_locks.advisory` count = **0** для мигрированных путей — это
подтверждает, что расширение работает без записей в LockManager
на этих конкретных путях в этой синтетической нагрузке. Это свойство
расширения, а не универсальное утверждение про advisory-локи; для
большинства нагрузок стандартный LockManager — правильный
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

# Записать все 4 сценария одной командой (от root; initdb/pg_ctl/psql
# делегируются в `postgres` user через `runuser`):
sudo scripts/record_flamegraphs.sh

# SVG'и появятся в docs/perf/flamegraphs/, top-15 leaves каждого
# сценария напечатается на stdout.
```

`scripts/record_flamegraphs.sh` сам выставляет
`kernel.kptr_restrict=0` и `kernel.perf_event_paranoid=-1` на время
прогона и восстанавливает исходные значения при выходе. Под капотом
делает то же, что было бы вручную через `perf record -F 997 -g -a`
на 12-секундное окно для каждого сценария, прогон workload через
`psql -h /tmp -p <port> ...`, генерация SVG через
`/opt/FlameGraph/stackcollapse-perf.pl | flamegraph.pl`.

`postgresql-17-dbgsym` ставит debug-info в `/usr/lib/debug/.build-id/...`;
`perf` находит файл по Build-ID автоматически. Без этого пакета все
функции PG core схлопнутся в `[postgres]` опаковый leaf, и top-15
будут информативны только по pg_xclaim symbols. Для source-level
kernel symbols дополнительно нужен `linux-image-$(uname -r)-dbgsym`
из ubuntu ddebs repo — без него kernel-фреймы имеют только имена
функций (через kallsyms), без файла/линии.

---

## Как читать SVG'и

Каждый блок в flamegraph — это функция в стеке вызовов:
- **Ширина** = процент CPU-времени (сэмплов)
- **Y-ось (вертикаль)** = глубина стека (root внизу)
- **Цвета** = только для визуального различия (без семантики при `--colors hot`)
- **Click — zoom in**, **Reset Zoom** — назад, **Search** — поиск подстроки по всем стекам

Что искать в `xclaim.try` flamegraph'ах:
- Широкие блоки `xclaim_local_lookup_with_hash` ближе к верху → доминирует быстрый путь повторного входа (внутри этой функции inline hash_bytes)
- Блоки над `LWLockAcquire`/`LWLockRelease` → горячие leaf'ы критической секции
- Блоки `[postgres]` → PG core (executor, planner, диспетчер вызова функций)
- Всё внутри ядра (`__x64_sys_*`, `do_*`, `entry_*`) → syscalls / обработчики page-fault
