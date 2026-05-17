"""
BaraDB LangChain Vector Store Integration

Usage:
    from baradb import Client, WireValue
    from baradb.langchain_store import BaraDBStore
    from langchain.embeddings import OpenAIEmbeddings

    client = Client("localhost", 9472)
    await client.connect()

    store = BaraDBStore(
        client=client,
        table="docs",
        embedding_col="embedding",
        text_col="content",
        embedding_function=OpenAIEmbeddings().embed_query,
        tenant_id="company-a"  # optional, for RLS
    )

    await store.add_texts(["hello world", "quick brown fox"])
    results = await store.similarity_search("hello", k=5)
"""

import json
from typing import Any, Callable, List, Optional, Sequence, Tuple


class BaraDBStore:
    """LangChain-compatible Vector Store for BaraDB."""

    def __init__(
        self,
        client: Any,
        table: str = "documents",
        embedding_col: str = "embedding",
        text_col: str = "content",
        metadata_cols: Optional[List[str]] = None,
        embedding_function: Optional[Callable[[str], List[float]]] = None,
        tenant_id: Optional[str] = None,
        vector_dimension: int = 1536,
    ):
        self.client = client
        self.table = table
        self.embedding_col = embedding_col
        self.text_col = text_col
        self.metadata_cols = metadata_cols or []
        self.embedding_function = embedding_function
        self.tenant_id = tenant_id
        self.vector_dimension = vector_dimension
        self._table_created = False

    def _wire(self, val: Any) -> Any:
        """Lazy import WireValue to avoid circular deps."""
        from baradb import WireValue
        if isinstance(val, str):
            return WireValue.string(val)
        if isinstance(val, int):
            return WireValue.int64(val)
        if isinstance(val, float):
            return WireValue.float64(val)
        if val is None:
            return WireValue.null()
        return WireValue.string(str(val))

    async def _ensure_table(self) -> None:
        if self._table_created:
            return
        # Create table with vector + text + tenant_id columns
        cols = f"id SERIAL PRIMARY KEY, {self.embedding_col} VECTOR({self.vector_dimension}), {self.text_col} TEXT"
        if self.tenant_id:
            cols += ", tenant_id TEXT"
        for mc in self.metadata_cols:
            cols += f", {mc} TEXT"
        await self.client.query(f"CREATE TABLE IF NOT EXISTS {self.table} ({cols})")

        # Create indexes if not exist
        idx_vec = f"idx_{self.table}_vec"
        idx_fts = f"idx_{self.table}_fts"
        await self.client.query(f"CREATE INDEX IF NOT EXISTS {idx_vec} ON {self.table}({self.embedding_col}) USING hnsw")
        await self.client.query(f"CREATE INDEX IF NOT EXISTS {idx_fts} ON {self.table}({self.text_col}) USING FTS")
        self._table_created = True

    async def add_texts(
        self,
        texts: Sequence[str],
        metadatas: Optional[List[dict]] = None,
        ids: Optional[List[str]] = None,
    ) -> List[str]:
        await self._ensure_table()
        if not self.embedding_function:
            raise ValueError("embedding_function is required for add_texts")

        inserted_ids: List[str] = []
        for i, text in enumerate(texts):
            vec = self.embedding_function(text)
            vec_str = "[" + ",".join(str(v) for v in vec) + "]"

            meta = metadatas[i] if metadatas and i < len(metadatas) else {}
            col_names = [self.embedding_col, self.text_col]
            params = [self._wire(vec_str), self._wire(text)]

            if self.tenant_id:
                col_names.append("tenant_id")
                params.append(self._wire(self.tenant_id))
            for mc in self.metadata_cols:
                if mc in meta:
                    col_names.append(mc)
                    params.append(self._wire(meta[mc]))

            placeholders = [f"${j + 1}" for j in range(len(params))]
            sql = (
                f"INSERT INTO {self.table} ({', '.join(col_names)}) "
                f"VALUES ({', '.join(placeholders)}) RETURNING id"
            )
            result = await self.client.query_params(sql, params)
            if result.rows:
                inserted_ids.append(result.rows[0].get("id", str(i)))
            else:
                inserted_ids.append(str(i))
        return inserted_ids

    async def similarity_search(
        self, query: str, k: int = 4, filter_col: Optional[str] = None, filter_val: Optional[str] = None
    ) -> List[Tuple[Any, float]]:
        await self._ensure_table()
        if not self.embedding_function:
            raise ValueError("embedding_function is required for similarity_search")

        vec = self.embedding_function(query)
        vec_str = "[" + ",".join(str(v) for v in vec) + "]"

        # Set tenant session variable if multi-tenant
        if self.tenant_id:
            await self.client.query_params(
                "SET app.tenant_id = $1", [self._wire(self.tenant_id)]
            )

        if filter_col and filter_val:
            sql = (
                "SELECT hybrid_search_filtered($1, $2, $3, $4, $5, $6, $7, $8) AS res"
            )
            params = [
                self._wire(self.table),
                self._wire(self.embedding_col),
                self._wire(self.text_col),
                self._wire(query),
                self._wire(vec_str),
                self._wire(k),
                self._wire(filter_col),
                self._wire(filter_val),
            ]
        else:
            sql = "SELECT hybrid_search($1, $2, $3, $4, $5, $6) AS res"
            params = [
                self._wire(self.table),
                self._wire(self.embedding_col),
                self._wire(self.text_col),
                self._wire(query),
                self._wire(vec_str),
                self._wire(k),
            ]

        result = await self.client.query_params(sql, params)
        if not result.rows:
            return []

        raw = result.rows[0].get("res", "[]")
        try:
            arr = json.loads(raw)
        except:
            return []

        docs: List[Tuple[Any, float]] = []
        for item in arr:
            doc_id = item.get("id", "")
            score = float(item.get("score", 0))
            # Fetch full row — use parameterized query
            row_result = await self.client.query_params(
                f"SELECT * FROM {self.table} WHERE id = $1",
                [self._wire(doc_id)],
            )
            if row_result.rows:
                page_content = row_result.rows[0].get(self.text_col, "")
                metadata = dict(row_result.rows[0])
                # Wrap in a simple Document-like object
                doc = _SimpleDocument(page_content=page_content, metadata=metadata)
                docs.append((doc, score))
        return docs

    async def max_marginal_relevance_search(
        self, query: str, k: int = 4, fetch_k: int = 20, lambda_mult: float = 0.5
    ) -> List[Any]:
        """MMR: diversify results while maintaining relevance."""
        await self._ensure_table()
        # Fetch more candidates
        candidates = await self.similarity_search(query, k=fetch_k)
        if not candidates:
            return []

        # Simple MMR: greedily select docs that maximize lambda*relevance - (1-lambda)*max_similarity_to_selected
        selected: List[Tuple[Any, float]] = []
        remaining = list(candidates)

        while len(selected) < k and remaining:
            best_score = -float("inf")
            best_idx = 0
            for i, (doc, rel_score) in enumerate(remaining):
                # Penalize similarity to already selected docs
                penalty = 0.0
                for sel_doc, _ in selected:
                    penalty = max(penalty, _doc_similarity(doc, sel_doc))
                mmr_score = lambda_mult * rel_score - (1 - lambda_mult) * penalty
                if mmr_score > best_score:
                    best_score = mmr_score
                    best_idx = i
            selected.append(remaining.pop(best_idx))

        return [doc for doc, _ in selected]

    async def delete(self, ids: Optional[List[str]] = None) -> None:
        await self._ensure_table()
        if ids:
            # Build parameterized IN clause: $1, $2, ...
            placeholders = [f"${j + 1}" for j in range(len(ids))]
            params = [self._wire(i) for i in ids]
            await self.client.query_params(
                f"DELETE FROM {self.table} WHERE id IN ({', '.join(placeholders)})",
                params,
            )

    async def set_tenant(self, tenant_id: str) -> None:
        self.tenant_id = tenant_id
        await self.client.query_params(
            "SET app.tenant_id = $1", [self._wire(tenant_id)]
        )


class _SimpleDocument:
    def __init__(self, page_content: str, metadata: dict):
        self.page_content = page_content
        self.metadata = metadata

    def __repr__(self):
        return f"Document(content={self.page_content[:50]}..., metadata={self.metadata})"


def _doc_similarity(a: _SimpleDocument, b: _SimpleDocument) -> float:
    """Simple Jaccard similarity on text tokens."""
    tokens_a = set(a.page_content.lower().split())
    tokens_b = set(b.page_content.lower().split())
    if not tokens_a or not tokens_b:
        return 0.0
    intersection = tokens_a & tokens_b
    union = tokens_a | tokens_b
    return len(intersection) / len(union)
