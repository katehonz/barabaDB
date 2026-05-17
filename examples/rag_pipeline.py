#!/usr/bin/env python3
"""
BaraDB RAG Pipeline — End-to-End Example

Demonstrates a complete RAG (Retrieval-Augmented Generation) pipeline:
1. Ingest a document (PDF or text)
2. Chunk into pieces
3. Generate embeddings via API (OpenAI / Ollama)
4. Store in BaraDB with vector + FTS indexes
5. Hybrid search for relevant chunks
6. Generate LLM response with context

Usage:
    # With Ollama (local):
    python rag_pipeline.py --file document.txt --embedder ollama --model nomic-embed-text

    # With OpenAI:
    python rag_pipeline.py --file document.pdf --embedder openai --api-key sk-...

    # Query mode (existing database):
    python rag_pipeline.py --query "What is the main topic?" --db-host localhost --db-port 9472

Requirements:
    pip install baradb requests pypdf2
"""

import argparse
import json
import os
import sys
import requests
from typing import List, Optional, Tuple

# ---------------------------------------------------------------------------
# Document loader
# ---------------------------------------------------------------------------

def load_document(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        try:
            from PyPDF2 import PdfReader
            reader = PdfReader(path)
            return "\n\n".join(page.extract_text() or "" for page in reader.pages)
        except ImportError:
            print("PyPDF2 not installed. pip install pypdf2")
            sys.exit(1)
    elif ext in (".txt", ".md", ".rst", ".py", ".nim", ".json", ".yaml", ".yml"):
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    else:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()


# ---------------------------------------------------------------------------
# Text chunking
# ---------------------------------------------------------------------------

def chunk_text(text: str, chunk_size: int = 1024, overlap: int = 128) -> List[str]:
    if len(text) <= chunk_size:
        return [text.strip()] if text.strip() else []

    chunks = []
    for para in text.split("\n\n"):
        para = para.strip()
        if not para:
            continue
        if len(para) <= chunk_size:
            chunks.append(para)
        else:
            sentences = []
            current = ""
            for ch in para:
                current += ch
                if ch in ".!?" and len(current) > chunk_size // 4:
                    sentences.append(current.strip())
                    current = ""
            if current.strip():
                sentences.append(current.strip())

            for sentence in sentences:
                if len(sentence) <= chunk_size:
                    chunks.append(sentence)
                else:
                    pos = 0
                    while pos < len(sentence):
                        end = min(pos + chunk_size, len(sentence))
                        chunk = sentence[pos:end].strip()
                        if chunk:
                            chunks.append(chunk)
                        pos += chunk_size - overlap

    return [c for c in chunks if len(c) >= 64]


# ---------------------------------------------------------------------------
# Embedding
# ---------------------------------------------------------------------------

def get_embedding_openai(text: str, model: str, api_key: str) -> Optional[List[float]]:
    resp = requests.post(
        "https://api.openai.com/v1/embeddings",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        json={"model": model, "input": text},
        timeout=30,
    )
    data = resp.json()
    if "data" in data and len(data["data"]) > 0:
        return data["data"][0]["embedding"]
    return None


def get_embedding_ollama(text: str, model: str, host: str = "http://localhost:11434") -> Optional[List[float]]:
    resp = requests.post(
        f"{host}/api/embeddings",
        json={"model": model, "prompt": text},
        timeout=30,
    )
    data = resp.json()
    if "embedding" in data:
        return data["embedding"]
    return None


def embed(texts: List[str], config: dict) -> List[Optional[List[float]]]:
    if config["type"] == "openai":
        return [get_embedding_openai(t, config["model"], config["api_key"]) for t in texts]
    elif config["type"] == "ollama":
        return [get_embedding_ollama(t, config["model"], config.get("host", "http://localhost:11434")) for t in texts]
    return [None] * len(texts)


# ---------------------------------------------------------------------------
# LLM
# ---------------------------------------------------------------------------

def generate_response(query: str, context: str, config: dict) -> str:
    prompt = f"""You are a helpful assistant. Answer the question based on the context below.
If the answer cannot be found in the context, say "I don't have enough information."

Context:
{context}

Question: {query}

Answer:"""

    if config["type"] == "openai":
        resp = requests.post(
            "https://api.openai.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {config['api_key']}", "Content-Type": "application/json"},
            json={"model": config.get("chat_model", "gpt-4o-mini"),
                  "messages": [{"role": "user", "content": prompt}]},
            timeout=60,
        )
        return resp.json()["choices"][0]["message"]["content"]

    elif config["type"] == "ollama":
        resp = requests.post(
            f"{config.get('host', 'http://localhost:11434')}/api/generate",
            json={"model": config.get("chat_model", "llama3"), "prompt": prompt, "stream": False},
            timeout=60,
        )
        return resp.json().get("response", "")

    return "No LLM configured."


# ---------------------------------------------------------------------------
# BaraDB integration
# ---------------------------------------------------------------------------

class BaraDBClient:
    """Simple HTTP client for BaraDB."""

    def __init__(self, host: str = "localhost", port: int = 9472):
        self.base = f"http://{host}:{port}"

    def execute(self, sql: str) -> dict:
        resp = requests.post(f"{self.base}/query", json={"query": sql}, timeout=30)
        return resp.json()

    def query_params(self, sql: str, params: list) -> dict:
        """Execute a parameterized query via HTTP API."""
        resp = requests.post(
            f"{self.base}/query",
            json={"query": sql, "params": params},
            timeout=30,
        )
        return resp.json()


def setup_bara_db(client: BaraDBClient, table: str = "rag_docs"):
    client.execute(f"""
        CREATE TABLE IF NOT EXISTS {table} (
            id INTEGER PRIMARY KEY AUTO_INCREMENT,
            chunk_index INTEGER,
            content TEXT,
            embedding VECTOR(1536),
            metadata TEXT
        )
    """)
    client.execute(f"CREATE INDEX IF NOT EXISTS {table}_vec ON {table}(embedding) USING hnsw")
    client.execute(f"CREATE INDEX IF NOT EXISTS {table}_fts ON {table}(content) USING fts")


def ingest_document(
    client: BaraDBClient,
    content: str,
    table: str,
    embedder_config: dict,
    chunk_size: int = 1024,
    overlap: int = 128,
):
    chunks = chunk_text(content, chunk_size, overlap)
    print(f"Split into {len(chunks)} chunks")

    batch_size = 10
    for batch_start in range(0, len(chunks), batch_size):
        batch = chunks[batch_start:batch_start + batch_size]
        embeddings = embed(batch, embedder_config)

        for i, (chunk, embedding) in enumerate(zip(batch, embeddings)):
            chunk_idx = batch_start + i
            if embedding:
                vec_str = "[" + ",".join(str(v) for v in embedding) + "]"
                client.query_params(
                    f"INSERT INTO {table} (chunk_index, content, embedding) "
                    f"VALUES (? , ?, ?)",
                    [chunk_idx, chunk, vec_str],
                )
            else:
                client.query_params(
                    f"INSERT INTO {table} (chunk_index, content) "
                    f"VALUES (?, ?)",
                    [chunk_idx, chunk],
                )

        print(f"  Ingested chunks {batch_start + 1}-{min(batch_start + batch_size, len(chunks))}")


def search(
    client: BaraDBClient,
    query: str,
    table: str,
    embedder_config: dict,
    k: int = 5,
) -> List[dict]:
    query_embedding = embed([query], embedder_config)[0]
    if query_embedding:
        vec_str = "[" + ",".join(str(v) for v in query_embedding) + "]"
        result = client.query_params(
            f"SELECT id, chunk_index, content, cos_distance(embedding, ?) AS distance "
            f"FROM {table} "
            f"ORDER BY distance ASC "
            f"LIMIT ?",
            [vec_str, k],
        )
    else:
        result = client.query_params(
            f"SELECT id, chunk_index, content FROM {table} LIMIT ?",
            [k],
        )

    if "rows" in result:
        return result["rows"]
    return []


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="BaraDB RAG Pipeline")
    parser.add_argument("--file", "-f", help="Document to ingest")
    parser.add_argument("--query", "-q", help="Query for RAG search")
    parser.add_argument("--db-host", default="localhost", help="BaraDB host")
    parser.add_argument("--db-port", type=int, default=9472, help="BaraDB port (HTTP = TCP + 440)")
    parser.add_argument("--table", default="rag_docs", help="Table name")
    parser.add_argument("--embedder", default="ollama", choices=["ollama", "openai", "none"])
    parser.add_argument("--model", default="nomic-embed-text", help="Embedding model")
    parser.add_argument("--api-key", help="API key (for OpenAI)")
    parser.add_argument("--api-host", default="http://localhost:11434", help="Ollama host")
    parser.add_argument("--chat-model", default="llama3", help="Chat model for generation")
    parser.add_argument("--chunk-size", type=int, default=1024)
    parser.add_argument("--overlap", type=int, default=128)
    parser.add_argument("--top-k", type=int, default=5, help="Number of chunks to retrieve")
    args = parser.parse_args()

    if not args.file and not args.query:
        parser.print_help()
        return

    client = BaraDBClient(args.db_host, args.db_port)
    setup_bara_db(client, args.table)

    embedder_config = {
        "type": args.embedder,
        "model": args.model,
        "api_key": args.api_key or os.getenv("OPENAI_API_KEY", ""),
        "host": args.api_host,
        "chat_model": args.chat_model,
    }

    if args.file:
        print(f"Loading: {args.file}")
        content = load_document(args.file)
        print(f"Loaded {len(content)} characters")

        ingest_document(client, content, args.table, embedder_config,
                        args.chunk_size, args.overlap)
        print("Ingestion complete.")

    if args.query:
        print(f"\nQuery: {args.query}")
        results = search(client, args.query, args.table, embedder_config, args.top_k)

        if not results:
            print("No results found.")
            return

        context = "\n\n".join(r.get("content", "") for r in results)
        print(f"\nTop {len(results)} chunks retrieved:")
        for r in results:
            print(f"  [{r.get('chunk_index', '?')}] {r.get('content', '')[:120]}...")

        answer = generate_response(args.query, context, embedder_config)
        print(f"\nAnswer:\n{answer}")


if __name__ == "__main__":
    main()
