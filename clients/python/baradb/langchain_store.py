"""
BaraDB LangChain Vector Store Integration

Usage:
    from baradb import Client
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
            meta_cols = []
            meta_vals = []
            if self.tenant_id:
                meta_cols.append("tenant_id")
                meta_vals.append(f"'{self.tenant_id}'")
            for mc in self.metadata_cols:
                if mc in meta:
                    meta_cols.append(mc)
                    meta_vals.append(f"'{meta[mc]}'")

            col_list = f"{self.embedding_col}, {self.text_col}"
            val_list = f"'{vec_str}', '{text.replace(\"'\", \"''\")}'"
            if meta_cols:
                col_list += ", " + ", ".join(meta_cols)
                val_list += ", " + ", ".join(meta_vals)

            sql = f"INSERT INTO {self.table} ({col_list}) VALUES ({val_list}) RETURNING id"
            result = await self.client.query(sql)
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
            await self.client.query(f"SET app.tenant_id = '{self.tenant_id}'")

        if filter_col and filter_val:
            sql = f"SELECT hybrid_search_filtered('{self.table}', '{self.embedding_col}', '{self.text_col}', '{query.replace(\"'\", \"''\")}', '{vec_str}', {k}, '{filter_col}', '{filter_val}') AS res"
        else:
            sql = f"SELECT hybrid_search('{self.table}', '{self.embedding_col}', '{self.text_col}', '{query.replace(\"'\", \"''\")}', '{vec_str}', {k}) AS res"

        result = await self.client.query(sql)
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
            # Fetch full row
            row_result = await self.client.query(f"SELECT * FROM {self.table} WHERE id = {doc_id}")
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
            id_list = ", ".join(str(i) for i in ids)
            await self.client.query(f"DELETE FROM {self.table} WHERE id IN ({id_list})")

    async def set_tenant(self, tenant_id: str) -> None:
        self.tenant_id = tenant_id
        await self.client.query(f"SET app.tenant_id = '{tenant_id}'")


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
