/**
 * BaraDB LangChain.js Vector Store Integration
 *
 * Usage:
 *   const { Client } = require('./baradb');
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

      const metaCols = [];
      const metaVals = [];
      if (this.tenantId) {
        metaCols.push('tenant_id');
        metaVals.push(`'${this.tenantId}'`);
      }
      for (const mc of this.metadataCols) {
        if (meta[mc] !== undefined) {
          metaCols.push(mc);
          metaVals.push(`'${String(meta[mc]).replace(/'/g, "''")}'`);
        }
      }

      let colList = `${this.embeddingCol}, ${this.textCol}`;
      let valList = `'${vecStr}', '${text.replace(/'/g, "''")}'`;
      if (metaCols.length > 0) {
        colList += ', ' + metaCols.join(', ');
        valList += ', ' + metaVals.join(', ');
      }

      const sql = `INSERT INTO ${this.table} (${colList}) VALUES (${valList}) RETURNING id`;
      const result = await this.client.query(sql);
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
      await this.client.query(`SET app.tenant_id = '${this.tenantId}'`);
    }

    let sql;
    if (filter && filter.column && filter.value) {
      sql = `SELECT hybrid_search_filtered('${this.table}', '${this.embeddingCol}', '${this.textCol}', '${query.replace(/'/g, "''")}', '${vecStr}', ${k}, '${filter.column}', '${filter.value}') AS res`;
    } else {
      sql = `SELECT hybrid_search('${this.table}', '${this.embeddingCol}', '${this.textCol}', '${query.replace(/'/g, "''")}', '${vecStr}', ${k}) AS res`;
    }

    const result = await this.client.query(sql);
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
      const rowResult = await this.client.query(`SELECT * FROM ${this.table} WHERE id = ${docId}`);
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
    const idList = ids.join(', ');
    await this.client.query(`DELETE FROM ${this.table} WHERE id IN (${idList})`);
  }

  async setTenant(tenantId) {
    this.tenantId = tenantId;
    await this.client.query(`SET app.tenant_id = '${tenantId}'`);
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
