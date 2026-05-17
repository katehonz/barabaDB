/**
 * BaraDB LangChain.js Vector Store Integration
 *
 * Usage:
 *   const { Client, WireValue } = require('./baradb');
 *   const { BaraDBStore } = require('./baradb_langchain');
 *
 *   const client = new Client('localhost', 9472);
 *   await client.connect();
 *
 *   const store = new BaraDBStore({
 *     client,
 *     table: 'docs',
 *     embeddingCol: 'embedding',
 *     textCol: 'content',
 *     embeddingFunction: async (text) => [0.1, 0.2, ...], // your embedder
 *     tenantId: 'company-a'
 *   });
 *
 *   await store.addDocuments([
 *     { pageContent: 'hello world', metadata: { source: 'web' } }
 *   ]);
 *
 *   const results = await store.similaritySearch('hello', 5);
 */

const { WireValue } = require('./baradb');

class BaraDBStore {
  constructor(options = {}) {
    this.client = options.client;
    this.table = options.table || 'documents';
    this.embeddingCol = options.embeddingCol || 'embedding';
    this.textCol = options.textCol || 'content';
    this.metadataCols = options.metadataCols || [];
    this.embeddingFunction = options.embeddingFunction || null;
    this.tenantId = options.tenantId || null;
    this.vectorDimension = options.vectorDimension || 1536;
    this._tableCreated = false;
  }

  async _ensureTable() {
    if (this._tableCreated) return;

    const cols = `id SERIAL PRIMARY KEY, ${this.embeddingCol} VECTOR(${this.vectorDimension}), ${this.textCol} TEXT` +
      (this.tenantId ? ', tenant_id TEXT' : '') +
      this.metadataCols.map(mc => `, ${mc} TEXT`).join('');

    await this.client.query(`CREATE TABLE IF NOT EXISTS ${this.table} (${cols})`);
    await this.client.query(`CREATE INDEX IF NOT EXISTS idx_${this.table}_vec ON ${this.table}(${this.embeddingCol}) USING hnsw`);
    await this.client.query(`CREATE INDEX IF NOT EXISTS idx_${this.table}_fts ON ${this.table}(${this.textCol}) USING FTS`);
    this._tableCreated = true;
  }

  async addDocuments(documents) {
    await this._ensureTable();
    if (!this.embeddingFunction) {
      throw new Error('embeddingFunction is required for addDocuments');
    }

    const insertedIds = [];
    for (const doc of documents) {
      const text = doc.pageContent || doc.content || '';
      const meta = doc.metadata || {};
      const vec = await this.embeddingFunction(text);
      const vecStr = '[' + vec.join(',') + ']';

      const colNames = [this.embeddingCol, this.textCol];
      const params = [WireValue.string(vecStr), WireValue.string(text)];

      if (this.tenantId) {
        colNames.push('tenant_id');
        params.push(WireValue.string(this.tenantId));
      }
      for (const mc of this.metadataCols) {
        if (meta[mc] !== undefined) {
          colNames.push(mc);
          params.push(WireValue.string(String(meta[mc])));
        }
      }

      const placeholders = params.map((_, i) => `$${i + 1}`).join(', ');
      const sql = `INSERT INTO ${this.table} (${colNames.join(', ')}) VALUES (${placeholders}) RETURNING id`;
      const result = await this.client.queryParams(sql, params);
      if (result.rows && result.rows.length > 0) {
        insertedIds.push(result.rows[0].id || result.rows[0][0]);
      }
    }
    return insertedIds;
  }

  async addTexts(texts, metadatas = []) {
    const docs = texts.map((text, i) => ({
      pageContent: text,
      metadata: metadatas[i] || {}
    }));
    return this.addDocuments(docs);
  }

  async similaritySearch(query, k = 4, filter = null) {
    await this._ensureTable();
    if (!this.embeddingFunction) {
      throw new Error('embeddingFunction is required for similaritySearch');
    }

    const vec = await this.embeddingFunction(query);
    const vecStr = '[' + vec.join(',') + ']';

    if (this.tenantId) {
      await this.client.queryParams('SET app.tenant_id = $1', [WireValue.string(this.tenantId)]);
    }

    let sql;
    let params;
    if (filter && filter.column && filter.value) {
      sql = 'SELECT hybrid_search_filtered($1, $2, $3, $4, $5, $6, $7, $8) AS res';
      params = [
        WireValue.string(this.table),
        WireValue.string(this.embeddingCol),
        WireValue.string(this.textCol),
        WireValue.string(query),
        WireValue.string(vecStr),
        WireValue.int32(k),
        WireValue.string(filter.column),
        WireValue.string(filter.value),
      ];
    } else {
      sql = 'SELECT hybrid_search($1, $2, $3, $4, $5, $6) AS res';
      params = [
        WireValue.string(this.table),
        WireValue.string(this.embeddingCol),
        WireValue.string(this.textCol),
        WireValue.string(query),
        WireValue.string(vecStr),
        WireValue.int32(k),
      ];
    }

    const result = await this.client.queryParams(sql, params);
    if (!result.rows || result.rows.length === 0) return [];

    const raw = result.rows[0].res || result.rows[0][0] || '[]';
    let arr;
    try {
      arr = JSON.parse(raw);
    } catch {
      return [];
    }

    const docs = [];
    for (const item of arr) {
      const docId = item.id;
      const score = parseFloat(item.score || 0);
      const rowResult = await this.client.queryParams(
        `SELECT * FROM ${this.table} WHERE id = $1`,
        [WireValue.string(String(docId))]
      );
      if (rowResult.rows && rowResult.rows.length > 0) {
        const row = rowResult.rows[0];
        const pageContent = row[this.textCol] || row[Object.keys(row).find(k => k.toLowerCase() === this.textCol.toLowerCase())];
        docs.push({
          pageContent: String(pageContent),
          metadata: { ...row, _score: score },
        });
      }
    }
    return docs;
  }

  async maxMarginalRelevanceSearch(query, k = 4, fetchK = 20, lambdaMult = 0.5) {
    const candidates = await this.similaritySearch(query, fetchK);
    if (candidates.length === 0) return [];

    const selected = [];
    const remaining = [...candidates];

    while (selected.length < k && remaining.length > 0) {
      let bestScore = -Infinity;
      let bestIdx = 0;
      for (let i = 0; i < remaining.length; i++) {
        const doc = remaining[i];
        // Use _score from metadata as relevance
        const relScore = doc.metadata?._score || 0;
        let penalty = 0;
        for (const sel of selected) {
          penalty = Math.max(penalty, _docSimilarity(doc, sel));
        }
        const mmrScore = lambdaMult * relScore - (1 - lambdaMult) * penalty;
        if (mmrScore > bestScore) {
          bestScore = mmrScore;
          bestIdx = i;
        }
      }
      selected.push(remaining.splice(bestIdx, 1)[0]);
    }
    return selected;
  }

  async delete(ids) {
    await this._ensureTable();
    if (!ids || ids.length === 0) return;
    const params = ids.map((id, i) => WireValue.string(String(id)));
    const placeholders = ids.map((_, i) => `$${i + 1}`).join(', ');
    await this.client.queryParams(
      `DELETE FROM ${this.table} WHERE id IN (${placeholders})`,
      params
    );
  }

  async setTenant(tenantId) {
    this.tenantId = tenantId;
    await this.client.queryParams('SET app.tenant_id = $1', [WireValue.string(tenantId)]);
  }
}

function _docSimilarity(a, b) {
  const tokensA = new Set(String(a.pageContent || '').toLowerCase().split(/\s+/));
  const tokensB = new Set(String(b.pageContent || '').toLowerCase().split(/\s+/));
  if (tokensA.size === 0 || tokensB.size === 0) return 0;
  const intersection = new Set([...tokensA].filter(x => tokensB.has(x)));
  const union = new Set([...tokensA, ...tokensB]);
  return intersection.size / union.size;
}

module.exports = { BaraDBStore };
