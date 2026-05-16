# Отчёт по лабораторной работе №3

**Тема:** Распределённые системы хранения данных. Репликация и обработка сбоя.

**Стенд:** PostgreSQL 16 + pgpool-II в Docker. Полная топология поднимается одной командой (`./scripts/00-up.sh`), весь сценарий лабораторной воспроизводится последовательным запуском скриптов `01..07`.

---

## Требования к выполнению работы

| Требование | Реализация |
|---|---|
| Одинаковые виртуальные машины (хосты) | 5 контейнеров с идентичным базовым образом `postgres:16` в одной bridge-сети `rshd-lab3-net` (172.28.0.0/16) |
| Сетевая связность | bridge-сеть Docker, контейнеры разрешают друг друга по DNS (`pg-a`, `pg-b`, `pg-c`, `pgpool`) |
| Отдельная машина для подключения | контейнер `pg-client` с установленным `psql`, подключается к точке входа `pgpool:9999` |
| ≥ 2 таблицы, столбца, строки | `customers` и `orders` (см. [postgres/init/01-schema.sql](postgres/init/01-schema.sql)); на старте 5 заказчиков и 4 заказа |
| Транзакции | в скрипте 03: `BEGIN…COMMIT`, `BEGIN…ROLLBACK`, пакетные INSERT |
| Несколько клиентских сессий | 5 независимых `psql`-подключений в [03-clients-rw.sh](scripts/03-clients-rw.sh); реальные backend-процессы видны в `pg_stat_activity` всех трёх узлов |

---

## Этап 1. Конфигурация репликации

### Топология

```
                pg-client ──► pgpool:9999
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
           pg-a              pg-b                  pg-c
         (primary)     (sync standby)        (async standby)
        172.28.0.10     172.28.0.11           172.28.0.12
```

### Как реализована синхронность

На pg-a в `postgresql.conf`:
```
synchronous_commit = on
synchronous_standby_names = 'pg-b-sync'
```

Каждый standby подключается со своим `application_name`:
- pg-b → `application_name=pg-b-sync` → попадает в список sync → **синхронная** реплика
- pg-c → `application_name=pg-c-async` → НЕ попадает в список → **асинхронная** реплика

### Доказательство sync vs async — [02-sync-vs-async.sh](scripts/02-sync-vs-async.sh)

Демонстрация на пути **записи** через сетевую изоляцию:

| Тест | Действие | Результат | Что доказывает |
|---|---|---|---|
| 1. async | `docker network disconnect pg-c` + INSERT на pg-a | INSERT завершён за ~10–50 мс | async-реплика **не в критическом пути** COMMIT |
| 2. sync  | `docker network disconnect pg-b` + INSERT на pg-a | INSERT висит, `wait_event=SyncRep` | sync-реплика **в критическом пути** COMMIT |
| 2*. возврат | `docker network connect pg-b` | INSERT завершается через 1–3 сек | блокировка снимается восстановлением sync-реплики |

Также подтверждается через `pg_stat_replication` на pg-a: для pg-b-sync `sync_state=sync`, для pg-c-async `sync_state=async`.

---

## Этап 2. Симуляция и обработка сбоя

### 2.1 Подготовка — [03-clients-rw.sh](scripts/03-clients-rw.sh)

Через pgpool открывается 5 параллельных клиентских сессий:

1. **Клиент 1 (запись + COMMIT):** транзакция INSERT customers + INSERT orders
2. **Клиент 2 (чтение):** SELECT последних заказов — pgpool маршрутизирует на реплику
3. **Клиент 3 (запись + ROLLBACK):** UPDATE + ROLLBACK, статус возвращается к исходному
4. **Клиент 4 (пакетная вставка):** 5 заказов через `generate_series`
5. **Клиент 5 (балансировка):** 6 SELECT-ов `inet_server_addr()` → видим разные IP, pgpool распределяет read-нагрузку

В `pg_stat_activity` на каждом из pg-a, pg-b, pg-c видны реальные клиентские backend-процессы.

### 2.2 Сбой — [04-simulate-failure.sh](scripts/04-simulate-failure.sh)

Перед сбоем вставлена маркерная запись `'before-failure'`.

Симуляция программной ошибки:
```bash
docker exec pg-a pkill -9 postgres
```
Так как postgres был PID 1, весь контейнер pg-a завершается — это эквивалентно полной гибели узла.

### 2.3 Обработка

**Релевантные сообщения в логах:**
- `docker logs pgpool`: `degenerate_backend ... node_id: 0`, `execute command: /scripts/failover.sh`, `failover: set new primary node: 1`
- `/var/log/pgpool/failover.log`: `Promoting pg-b ... Successfully promoted`
- `docker logs pg-a`: последние записи перед остановкой

**Автоматический failover:** pgpool обнаружил недоступность primary → запустил [pgpool/failover.sh](pgpool/failover.sh), который:
1. Выполнил `SELECT pg_promote()` на pg-b
2. Сбросил `synchronous_standby_names = ''` на новом primary, чтобы COMMIT не блокировался отсутствующей sync-репликой

**После failover** (`SHOW POOL_NODES`):
- pg-a → `down`
- pg-b → `primary` ← новый
- pg-c → `standby`

**Работа клиентов после failover** — [05-clients-after-failover.sh](scripts/05-clients-after-failover.sh):

Через тот же URI `pgpool:9999` (клиентская строка подключения не менялась) выполнены:
- INSERT 5 заказов `after-failover-*`
- Транзакция с новым клиентом `eve` + заказ Camera
- SELECT — видна вся хронология: `before-failure` → `after-failover-*` → Camera

---

## Восстановление — [06-recover.sh](scripts/06-recover.sh)

Возврат к исходной конфигурации (A=primary, B=sync, C=async) в 8 шагов:

| Шаг | Действие | Зачем |
|---|---|---|
| 1 | Удалить контейнер pg-a и стереть его data | WAL-цепочка разошлась с pg-b в момент сбоя, простое поднятие невозможно |
| 2 | Поднять pg-a как standby текущего primary (pg-b) через `docker-compose.recover.yml` | `pg_basebackup` копирует актуальные данные с pg-b |
| 3 | Дождаться подключения pg-a к pg-b | `pg_stat_replication` на pg-b показывает `pg-a-recover` |
| 4 | Дождаться выравнивания LSN | `pg_current_wal_lsn(pg-b) == pg_last_wal_replay_lsn(pg-a)` |
| 5 | Контролируемое переключение pg-b → pg-a: `pg_ctl stop` + `pg_promote()` на pg-a + восстановление `synchronous_standby_names` | возврат primary-роли на pg-a без потери данных |
| 6 | Пересоздать pg-b с чистым volume | пере-инициализация как sync-standby pg-a |
| 7 | Пересоздать pg-c с чистым volume | пере-инициализация как async-standby pg-a |
| 8 | Пересоздать pgpool | pgpool хранит статус узлов в `pgpool_status` — пересоздание контейнера сбрасывает «зависшие» состояния |

### Финальная проверка — [07-final-verify.sh](scripts/07-final-verify.sh)

- Топология вернулась: A=`primary`, B=`sync standby`, C=`async standby`
- `pg_stat_replication` на A снова показывает две строки: pg-b-sync=`sync`, pg-c-async=`async`
- `SHOW POOL_NODES`: все три узла `up`
- Все данные сохранены: `before-failure`, `after-failover-*`, `Camera (eve)` присутствуют на всех узлах
- Финальный R/W-тест через pgpool: INSERT `after-recovery` + SELECT — запись прошла успешно

---

## Выводы

1. **Streaming-репликация PostgreSQL** настроена тремя способами синхронизации (sync для pg-b, async для pg-c) и продемонстрирована наблюдаемая разница на пути записи (зависание COMMIT на `wait_event=SyncRep` для sync, мгновенный COMMIT для async).
2. **pgpool-II** как единая точка входа реализует балансировку чтения и автоматический failover. Клиентская строка подключения (`pgpool:9999`) остаётся неизменной до, во время и после сбоя.
3. **Failover** в типовом стенде занимает 30–60 секунд от `pkill -9 postgres` до момента, когда pg-b принимает запись как новый primary.
4. **Восстановление** требует ручного шага (`06-recover.sh`), так как pgpool сам не возвращает упавший узел в кластер; данные с момента сбоя не теряются благодаря sync-репликации на pg-b.
