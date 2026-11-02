-- sudo homelab MCP knowledge base (runs once, on the first start of the database).
-- One table for every kind of entry; 1024-dim vectors from bge-m3.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS kb;

CREATE TABLE IF NOT EXISTS kb.documents (
    id          bigserial PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('knowledge', 'memory', 'script', 'document')),
    source      text NOT NULL,
    chunk_index integer NOT NULL DEFAULT 0,
    title       text,
    content     text NOT NULL,
    meta        jsonb NOT NULL DEFAULT '{}'::jsonb,
    emb         vector(1024),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(content, '')), 'B')) STORED
);

CREATE UNIQUE INDEX IF NOT EXISTS documents_identity ON kb.documents (kind, source, chunk_index);
CREATE INDEX IF NOT EXISTS documents_kind ON kb.documents (kind);
CREATE INDEX IF NOT EXISTS documents_emb ON kb.documents USING hnsw (emb vector_cosine_ops)
    WITH (m = 32, ef_construction = 128);
CREATE INDEX IF NOT EXISTS documents_tsv ON kb.documents USING gin (tsv);
CREATE INDEX IF NOT EXISTS documents_meta ON kb.documents USING gin (meta jsonb_path_ops);
CREATE INDEX IF NOT EXISTS documents_title_trgm ON kb.documents USING gin (title gin_trgm_ops);

CREATE OR REPLACE FUNCTION kb.touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS documents_touch ON kb.documents;
CREATE TRIGGER documents_touch BEFORE UPDATE ON kb.documents
    FOR EACH ROW EXECUTE FUNCTION kb.touch_updated_at();

-- Hybrid recall: vector nearest neighbours fused with full-text matches
-- (Reciprocal Rank Fusion). Works with query_emb NULL (text only).
CREATE OR REPLACE FUNCTION kb.search(
    query_text text, query_emb vector DEFAULT NULL, kind_filter text[] DEFAULT NULL,
    max_results integer DEFAULT 10, rrf_k integer DEFAULT 60, candidates integer DEFAULT 60)
RETURNS TABLE (id bigint, kind text, source text, chunk_index integer, title text,
               content text, meta jsonb, score double precision, created_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH vec AS (
    SELECT d.id, row_number() OVER (ORDER BY d.emb <=> query_emb) AS r
    FROM kb.documents d
    WHERE query_emb IS NOT NULL AND d.emb IS NOT NULL
      AND (kind_filter IS NULL OR d.kind = ANY(kind_filter))
    ORDER BY d.emb <=> query_emb
    LIMIT candidates
  ),
  txt AS (
    SELECT d.id, row_number() OVER (
             ORDER BY ts_rank_cd(d.tsv, websearch_to_tsquery('english', query_text)) DESC) AS r
    FROM kb.documents d
    WHERE coalesce(query_text, '') <> ''
      AND d.tsv @@ websearch_to_tsquery('english', query_text)
      AND (kind_filter IS NULL OR d.kind = ANY(kind_filter))
    LIMIT candidates
  ),
  fused AS (
    SELECT coalesce(v.id, t.id) AS id,
           coalesce(1.0 / (rrf_k + v.r), 0) + coalesce(1.0 / (rrf_k + t.r), 0) AS score
    FROM vec v FULL OUTER JOIN txt t ON v.id = t.id
  )
  SELECT d.id, d.kind, d.source, d.chunk_index, d.title, d.content, d.meta,
         f.score::double precision, d.created_at
  FROM fused f JOIN kb.documents d ON d.id = f.id
  ORDER BY f.score DESC, d.id
  LIMIT max_results;
$$;
