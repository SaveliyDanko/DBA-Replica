# RSHD Lab 3 — Репликация PostgreSQL с pgpool-II в Docker

Стенд для лабораторной по теме *"Распределённые системы хранения данных. Репликация и обработка сбоя"*.
Вместо ВМ используются Docker-контейнеры в одной bridge-сети.

## Топология

```
                   ┌─────────────┐
   pg-client  ───▶ │   pgpool    │  :9999    (load balance + failover)
                   └──────┬──────┘
                          │
       ┌──────────────────┼──────────────────┐
       ▼                  ▼                  ▼
   ┌────────┐         ┌────────┐         ┌────────┐
   │  pg-a  │ ──sync─▶│  pg-b  │         │  pg-c  │
   │primary │         │standby │         │standby │
   └────────┘ ──async────────────────────▶└────────┘
```

| Контейнер | IP            | Роль                                | application_name |
|-----------|---------------|-------------------------------------|------------------|
| pg-a      | 172.28.0.10   | основной                            | `pg-a-primary`   |
| pg-b      | 172.28.0.11   | синхронная реплика                  | `pg-b-sync`      |
| pg-c      | 172.28.0.12   | асинхронная реплика                 | `pg-c-async`     |
| pgpool    | 172.28.0.20   | менеджер кластера, точка входа :9999| —                |
| pg-client | 172.28.0.30   | "клиентская ВМ" с `psql`            | —                |

Синхронность реализована на стороне A: `synchronous_standby_names = 'pg-b-sync'`.
Узел B подключается с `application_name=pg-b-sync` → sync. C — с другим именем → async.

## Структура репозитория

```
.
├── docker-compose.yml              базовая конфигурация стенда
├── docker-compose.recover.yml      override для восстановления pg-a
├── postgres/
│   ├── Dockerfile                  образ postgres:16 + наш entrypoint
│   ├── entrypoint.sh               primary/standby init по NODE_ROLE
│   └── init/01-schema.sql          таблицы customers, orders + данные
├── pgpool/
│   ├── Dockerfile                  pgpool-II на debian:bookworm-slim
│   ├── pgpool.conf                 streaming_replication, lb, failover
│   ├── pool_hba.conf
│   ├── entrypoint.sh               генерация pool_passwd/pcp.conf, запуск
│   └── failover.sh                 pg_promote + сброс sync_names
└── scripts/
    ├── 00-up.sh                    поднять стенд с нуля
    ├── 01-show-cluster.sh          этап 1: показать конфигурацию
    ├── 02-sync-vs-async.sh         этап 1: продемонстрировать sync vs async
    ├── 03-clients-rw.sh            этап 2.1: клиенты R/W
    ├── 04-simulate-failure.sh      этап 2.2-2.3: pkill -9 + failover
    ├── 05-clients-after-failover.sh клиенты после failover
    ├── 06-recover.sh               восстановить исходную конфигурацию
    ├── 07-final-verify.sh          итоговая проверка
    └── 99-down.sh                  очистить стенд
```

## Требования

* Docker ≥ 24 c плагином Compose v2.
* **Доступ в интернет** для скачивания базовых образов `postgres:16` и
  `debian:bookworm-slim` (Debian ставит пакет `pgpool2`).
* Свободные TCP-порты на хосте: 9999 (pgpool).

## Как протестировать

### Полный прогон с нуля

```bash
cd RSHD_LAB_3

# Очистка + поднятие
./scripts/99-down.sh                     # удалить все контейнеры и volume'ы
./scripts/00-up.sh                       # билд + запуск + ожидание health

# Этап 1: конфигурация
./scripts/01-show-cluster.sh             # роли, pg_stat_replication, SHOW POOL_NODES
./scripts/02-sync-vs-async.sh            # доказательство sync vs async через pg_wal_replay_pause

# Этап 2.1: клиенты R/W
./scripts/03-clients-rw.sh               # несколько сессий, транзакции COMMIT/ROLLBACK

# Этап 2.2 + 2.3: симуляция сбоя и failover
./scripts/04-simulate-failure.sh         # pkill -9 postgres на pg-a, логи, авто-failover
./scripts/05-clients-after-failover.sh   # клиенты пишут/читают через pgpool, primary теперь pg-b

# Восстановление
./scripts/06-recover.sh                  # rebuild A → switchover B→A → rebuild B и C
./scripts/07-final-verify.sh             # топология вернулась, данные сохранены
```

Если что-то пошло криво посередине — `./scripts/99-down.sh && ./scripts/00-up.sh`
всегда возвращает стенд в исходное состояние.

### Что проверять глазами на каждом этапе

| Этап | Ожидаемый сигнал |
|------|------------------|
| `01-show-cluster.sh` | `pg-a: false`, `pg-b: true`, `pg-c: true`; в `pg_stat_replication` две строки — `pg-b-sync = sync`, `pg-c-async = async`; в `SHOW POOL_NODES` все три `up` |
| `02-sync-vs-async.sh` | После INSERT и до `resume`: на A=9, B=9, **C=4** (отстаёт). После `pg_wal_replay_resume()` — C=9 |
| `03-clients-rw.sh` | Транзакция с `dave` коммитится, заказ создан; транзакция с `ROLLBACK` не меняет статусы; в `pg_stat_activity` видны клиентские бэкенды на всех трёх узлах |
| `04-simulate-failure.sh` | В логах pgpool: `degenerate_backend ... node_id: 0`, `execute command: /scripts/failover.sh`, `failover: set new primary node: 1`. В `/var/log/pgpool/failover.log`: `Promoting pg-b ... Successfully promoted`. После — `pg-a = down`, `pg-b = primary` |
| `05-clients-after-failover.sh` | `INSERT` и `BEGIN/COMMIT` через `pgpool:9999` отрабатывают; новые строки появляются на pg-b |
| `06-recover.sh` | В выводе: `pg-a догнал pg-b`, `pg_promote() = t`, финальная топология: `A in_recovery? false`, `B in_recovery? true`, `C in_recovery? true`, в `pg_stat_replication` снова две строки sync+async |
| `07-final-verify.sh` | Счётчики `orders` совпадают на всех трёх узлах; в результате `SELECT` присутствуют записи `before-failure`, `after-failover-*`, `Camera` (eve), и финальная `after-recovery` создаётся успешно через pgpool |

### Полезные команды для интерактивной отладки

```bash
# psql через pgpool (точка входа для клиентов)
docker exec -it pg-client psql 'host=pgpool port=9999 user=postgres password=postgres dbname=labdb'

# psql напрямую к узлу
docker exec -it pg-a psql -U postgres -d labdb
docker exec -it pg-b psql -U postgres -d labdb
docker exec -it pg-c psql -U postgres -d labdb

# Состояние кластера в pgpool
docker exec pg-client psql 'host=pgpool port=9999 user=postgres password=postgres' \
  -c "SHOW POOL_NODES;"

# Репликация со стороны primary
docker exec pg-a psql -U postgres -c \
  "SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag
     FROM pg_stat_replication;"

# Логи
docker logs pg-a
docker logs pgpool
docker exec pgpool cat /var/log/pgpool/failover.log
```

## Что показывает каждый этап

### `01-show-cluster.sh` (этап 1: репликация настроена)

* `pg_is_in_recovery()` — `false` на A, `true` на B и C.
* `pg_stat_replication` на A: две строки с `sync_state = sync` для `pg-b-sync`
  и `sync_state = async` для `pg-c-async`.
* `SHOW POOL_NODES` из pgpool — три узла со статусами `up`, роль `primary`/`standby`,
  load-balance weight, replication delay.

### `02-sync-vs-async.sh` (этап 1: демонстрация задержки)

1. На C приостанавливается применение WAL: `SELECT pg_wal_replay_pause()`.
2. Через pgpool на A пишутся 5 заказов.
3. На B данные появляются мгновенно (sync ждёт fsync на B).
4. На C тех же данных пока нет — виден растущий `replay_lag` в
   `pg_stat_replication` на A.
5. `SELECT pg_wal_replay_resume()` — данные доходят до C.

### `03-clients-rw.sh` (этап 2.1)

Делается несколько отдельных сессий через `psql`:

* транзакция `INSERT customers + INSERT orders + COMMIT`;
* транзакция с `ROLLBACK`;
* пакетная вставка;
* несколько `SELECT inet_server_addr(), pg_is_in_recovery()` — видно,
  что pgpool балансирует read-запросы между узлами;
* `pg_stat_activity` на каждом узле показывает реальные клиентские сессии.

### `04-simulate-failure.sh` (этапы 2.2 и 2.3)

* Перед сбоем вставляется маркер `'before-failure'`.
* `docker exec pg-a pkill -9 postgres` — основной узел "умирает"
  (контейнер тоже завершается, т.к. postgres был PID 1).
* Скрипт показывает релевантные сообщения:
  * из `docker logs pg-a` — последние строки журнала перед смертью;
  * из `docker logs pgpool` — `find_primary_node`, `degenerate_backend`,
    `failover` — pgpool обнаружил отказ;
  * из `/var/log/pgpool/failover.log` — вывод нашего скрипта `failover.sh`.
* Скрипт `failover.sh` вызывает `pg_promote()` на pg-b и сбрасывает
  `synchronous_standby_names = ''`, чтобы новые транзакции не блокировались.
* После failover `SHOW POOL_NODES` показывает, что pg-b теперь `primary`,
  pg-a — `down`, pg-c — `standby`.

### `05-clients-after-failover.sh` (этап 2.3 завершение)

Клиенты продолжают писать и читать через тот же URI `pgpool:9999`.
Демонстрируется, что записи фактически попадают на pg-b и читаются обратно.

### `06-recover.sh` (восстановление)

1. **Удаляем устаревшие данные pg-a** (его WAL-цепочка разошлась с pg-b
   в момент сбоя — простой `pg_rewind` обычно достаточно, но для
   надёжности и наглядности делаем чистый `pg_basebackup`).
2. **Поднимаем pg-a как standby pg-b** через override-файл
   `docker-compose.recover.yml`.
3. **Ждём, пока pg-a догонит pg-b** по LSN (`pg_current_wal_lsn` ==
   `pg_last_wal_replay_lsn`).
4. **Контролируемое переключение B → A:**
   * `pg_ctl -m fast stop` на pg-b;
   * `SELECT pg_promote()` на pg-a;
   * `ALTER SYSTEM SET synchronous_standby_names = 'pg-b-sync'` на pg-a.
5. **Пересоздаём pg-b и pg-c** с чистыми data-volume — entrypoint снова
   сделает `pg_basebackup` с pg-a.
6. **Перезапускаем pgpool**, чтобы он переоценил топологию.

Все данные, записанные на этапах 2.3 и 4-6, сохраняются — они дошли до A
через сначала pg-b (standby), потом A стал primary и реплицирует их обратно
на B и C.

### `07-final-verify.sh`

Проверяет, что после восстановления:

* A снова primary, B — sync standby, C — async standby;
* в таблицах есть все записи, включая `'before-failure'`, `'after-failover-*'`,
  `'after-recovery'`.

## Ручная отладка через psql

```bash
# Подключиться к pgpool с клиентского контейнера:
docker exec -it pg-client psql 'host=pgpool port=9999 user=postgres password=postgres dbname=labdb'

# Подключиться напрямую к конкретному узлу:
docker exec -it pg-a psql -U postgres -d labdb
docker exec -it pg-b psql -U postgres -d labdb
docker exec -it pg-c psql -U postgres -d labdb

# Pgpool команды (только через порт pgpool):
docker exec pg-client psql 'host=pgpool port=9999 user=postgres password=postgres' -c "SHOW POOL_NODES;"
docker exec pg-client psql 'host=pgpool port=9999 user=postgres password=postgres' -c "SHOW POOL_PROCESSES;"
```

## Тонкие моменты конфигурации

* **`wal_log_hints = on`** на всех узлах — нужно для `pg_rewind` (на случай,
  если в будущем понадобится более лёгкое восстановление вместо `pg_basebackup`).
* **`synchronous_standby_names = ''`** на standby-узлах — чтобы после
  `pg_promote()` свежеиспечённый primary не блокировался на ожидании
  несуществующих синхронных реплик. Реальное имя восстанавливается
  скриптом `06-recover.sh`.
* **`backend_clustering_mode = 'streaming_replication'`** — современная директива
  pgpool 4.x вместо устаревших `master_slave_mode` + `master_slave_sub_mode`.
* **PCP** настроен: `pcp.conf` генерируется автоматически из переменной
  `POSTGRES_PASSWORD` в `pgpool/entrypoint.sh`; пароль хешируется через md5.
* **pool_hba.conf** разрешает md5-аутентификацию из подсети 172.28.0.0/16,
  `pool_passwd` собирается из `POSTGRES_PASSWORD` и `REPL_PASSWORD`.

## Известные ограничения

* После `pkill -9 postgres` контейнер pg-a завершается (postgres был PID 1).
  В реальной инфраструктуре systemd/k8s перезапустил бы процесс — здесь
  это эквивалентно "погиб весь узел", что соответствует духу симуляции.
* Между failover и запуском `06-recover.sh` pg-c остаётся подключенным
  к мёртвому pg-a (его `primary_conninfo` указывает на pg-a). Это не
  критично для лабораторной — pg-c всё равно становится reachable на чтение
  с устаревшими данными; полная синхронизация восстанавливается на шаге 6.
* В `failover.sh` мы не делаем `follow_primary_command` для pg-c, потому что
  на следующем шаге всё равно пересоздаём оба standby с нуля.
