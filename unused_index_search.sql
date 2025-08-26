## My SQL 

-- 1) Your Query-1 becomes CTE "idx"  ➜  2) filter to "candidates"
-- 3) build index column list          ➜  4) list FKs on the same tables
-- 5) report whether index leads any FK (prefix match)
WITH idx AS (                                   -- = your first query's inner SELECT
  SELECT
    ns.nspname  AS schema_name,
    tbl.relname AS table_name,
    idx.relname AS index_name,
    s.idx_scan,
    pg_relation_size(idx.oid)                  AS index_bytes,
    pg_size_pretty(pg_relation_size(idx.oid))  AS index_size,
    pg_get_indexdef(idx.oid)                   AS index_def,
    i.indisprimary,
    i.indisunique,
    i.indisvalid,
    con.conname                                AS constraint_name,
    idx.oid                                    AS index_oid,
    tbl.oid                                    AS table_oid
  FROM pg_class tbl
  JOIN pg_namespace ns   ON ns.oid = tbl.relnamespace
  JOIN pg_index i        ON i.indrelid = tbl.oid
  JOIN pg_class idx      ON idx.oid = i.indexrelid
  JOIN pg_stat_all_indexes s ON s.indexrelid = idx.oid
  LEFT JOIN pg_constraint con ON con.conindid = i.indexrelid
  WHERE tbl.relkind IN ('r','p')
    AND ns.nspname = 'qa_legal_suit_service_master'   -- <-- your schema
),
candidates AS (          -- exactly your Query-1 filters
  SELECT *
  FROM idx
  WHERE idx_scan = 0
    AND index_bytes > 50*1024*1024
    AND constraint_name IS NULL
    AND NOT indisprimary
    AND NOT indisunique
    AND indisvalid
),
idx_cols AS (            -- column list (in order) for each candidate index
  SELECT
    c.index_oid,
    ARRAY_AGG(a.attname ORDER BY k.ordinality) AS index_cols
  FROM candidates c
  JOIN pg_index ix ON ix.indexrelid = c.index_oid
  LEFT JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY k(attnum, ordinality) ON true
  LEFT JOIN pg_attribute a ON a.attrelid = c.table_oid AND a.attnum = k.attnum
  GROUP BY c.index_oid
),
fks AS (                 -- FK columns (in order) per FK on those tables
  SELECT
    conrelid                                   AS table_oid,
    conname                                    AS fk_name,
    ARRAY_AGG(a.attname ORDER BY u.ord)        AS fk_cols
  FROM pg_constraint
  JOIN LATERAL unnest(conkey) WITH ORDINALITY u(attnum, ord) ON true
  JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = u.attnum
  WHERE contype = 'f'
  GROUP BY conrelid, conname
)
SELECT
  c.schema_name,
  c.table_name,
  c.index_name,
  c.index_size,
  ic.index_cols,
  m.fk_name,
  m.fk_cols,
  (m.fk_name IS NOT NULL) AS index_leads_fk        -- TRUE means "keep (FK helper)"
FROM candidates c
JOIN idx_cols ic ON ic.index_oid = c.index_oid
LEFT JOIN LATERAL (
  -- find any FK on this table where FK columns are a prefix of the index columns
  SELECT fk_name, fk_cols
  FROM fks f
  WHERE f.table_oid = c.table_oid
    AND ic.index_cols[1:array_length(f.fk_cols,1)] = f.fk_cols
  LIMIT 1
) m ON TRUE
ORDER BY c.index_bytes DESC;

	-- 1.	Find long-running transactions (biggest cause of delays)

SELECT pid, usename, application_name, state,
       now() - xact_start AS xact_age, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;

	-- 2.	Make sure nothing is holding locks on the index
-- replace your_schema.your_index_name
SELECT l.locktype, l.mode, l.granted, a.pid, a.query
FROM pg_locks l
JOIN pg_class c ON c.oid = l.relation
LEFT JOIN pg_stat_activity a ON a.pid = l.pid
WHERE c.relname = 'your_index_name' AND a.pid IS DISTINCT FROM pg_backend_pid();
