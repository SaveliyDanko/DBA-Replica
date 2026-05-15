-- Демонстрационная схема для лабораторной работы
-- Две таблицы: customers и orders, разные столбцы, поддержка транзакций

CREATE TABLE customers (
    id           SERIAL PRIMARY KEY,
    username     TEXT NOT NULL UNIQUE,
    email        TEXT NOT NULL,
    full_name    TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE orders (
    id           SERIAL PRIMARY KEY,
    customer_id  INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    product      TEXT NOT NULL,
    quantity     INTEGER NOT NULL CHECK (quantity > 0),
    amount       NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    status       TEXT NOT NULL DEFAULT 'new',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status   ON orders(status);

INSERT INTO customers (username, email, full_name) VALUES
    ('alice',   'alice@example.com',   'Alice Anderson'),
    ('bob',     'bob@example.com',     'Bob Brown'),
    ('carol',   'carol@example.com',   'Carol Clark');

INSERT INTO orders (customer_id, product, quantity, amount, status) VALUES
    (1, 'Book',      2, 29.98,  'paid'),
    (1, 'Pen',      10,  9.90,  'paid'),
    (2, 'Laptop',    1, 1299.00,'shipped'),
    (3, 'Notebook',  3, 14.97,  'new');

-- Грант для пользователя репликации, чтобы pgpool мог проверять состояние
GRANT CONNECT ON DATABASE labdb TO replicator;
