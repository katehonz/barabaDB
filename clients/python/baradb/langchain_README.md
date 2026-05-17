# BaraDB LangChain Integration

## Python

```python
import asyncio
from baradb import Client
from baradb.langchain_store import BaraDBStore

async def main():
    client = Client("localhost", 9472)
    await client.connect()

    # Use OpenAI, sentence-transformers, or any embedder
    def embed(text: str) -> list[float]:
        # Replace with your embedding model
        return [0.1, 0.2, 0.3]

    store = BaraDBStore(
        client=client,
        table="knowledge",
        embedding_function=embed,
        tenant_id="tenant-a",
        vector_dimension=3,
    )

    await store.add_texts(["BaraDB is fast", "Vector search in SQL"])
    results = await store.similarity_search("fast database", k=5)
    for doc, score in results:
        print(doc.page_content, score)

asyncio.run(main())
```

## JavaScript

```javascript
const { Client } = require('./baradb');
const { BaraDBStore } = require('./baradb_langchain');

async function main() {
    const client = new Client('localhost', 9472);
    await client.connect();

    const store = new BaraDBStore({
        client,
        table: 'knowledge',
        embeddingFunction: async (text) => [0.1, 0.2, 0.3],
        tenantId: 'tenant-a',
        vectorDimension: 3,
    });

    await store.addTexts(['BaraDB is fast', 'Vector search in SQL']);
    const results = await store.similaritySearch('fast database', 5);
    console.log(results);
}

main();
```

## Features

- `add_texts()` / `addDocuments()` — auto-generate embeddings + INSERT
- `similarity_search()` — uses `hybrid_search()` (vector + FTS + RRF)
- `max_marginal_relevance_search()` — MMR reranking for diversity
- `delete()` — remove by IDs
- Multi-tenant — `tenant_id` sets session variable + metadata filter
