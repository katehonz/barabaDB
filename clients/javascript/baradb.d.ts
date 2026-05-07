// BaraDB JavaScript/TypeScript Client Type Definitions

export declare const MsgKind: Readonly<{
  CLIENT_HANDSHAKE: 0x01;
  QUERY: 0x02;
  QUERY_PARAMS: 0x03;
  EXECUTE: 0x04;
  BATCH: 0x05;
  TRANSACTION: 0x06;
  CLOSE: 0x07;
  PING: 0x08;
  AUTH: 0x09;
  SERVER_HANDSHAKE: 0x80;
  READY: 0x81;
  DATA: 0x82;
  COMPLETE: 0x83;
  ERROR: 0x84;
  AUTH_CHALLENGE: 0x85;
  AUTH_OK: 0x86;
  SCHEMA_CHANGE: 0x87;
  PONG: 0x88;
  TRANSACTION_STATE: 0x89;
}>;

export declare const FieldKind: Readonly<{
  NULL: 0x00;
  BOOL: 0x01;
  INT8: 0x02;
  INT16: 0x03;
  INT32: 0x04;
  INT64: 0x05;
  FLOAT32: 0x06;
  FLOAT64: 0x07;
  STRING: 0x08;
  BYTES: 0x09;
  ARRAY: 0x0A;
  OBJECT: 0x0B;
  VECTOR: 0x0C;
  JSON: 0x0D;
}>;

export declare const ResultFormat: Readonly<{
  BINARY: 0x00;
  JSON: 0x01;
  TEXT: 0x02;
}>;

export declare class WireValue {
  kind: number;
  value: any;
  constructor(kind: number, value?: any);
  static null(): WireValue;
  static bool(val: boolean): WireValue;
  static int8(val: number): WireValue;
  static int16(val: number): WireValue;
  static int32(val: number): WireValue;
  static int64(val: number | bigint): WireValue;
  static float32(val: number): WireValue;
  static float64(val: number): WireValue;
  static string(val: string): WireValue;
  static bytes(val: Buffer): WireValue;
  static array(val: WireValue[]): WireValue;
  static object(val: Record<string, WireValue>): WireValue;
  static vector(val: number[]): WireValue;
  static json(val: string): WireValue;
  serialize(): Buffer;
}

export interface QueryResultRow {
  [column: string]: any;
}

export declare class QueryResult implements Iterable<QueryResultRow> {
  columns: string[];
  columnTypes: number[];
  rows: any[][];
  rowCount: number;
  affectedRows: number;
  [Symbol.iterator](): Iterator<QueryResultRow>;
  get length(): number;
}

export interface ClientOptions {
  database?: string;
  username?: string;
  password?: string;
  timeout?: number;
}

export declare class Client {
  constructor(host?: string, port?: number, options?: ClientOptions);
  connect(): Promise<void>;
  close(): Promise<void>;
  isConnected(): boolean;
  auth(token: string): Promise<void>;
  ping(): Promise<boolean>;
  query(sql: string): Promise<QueryResult>;
  queryParams(sql: string, params?: WireValue[]): Promise<QueryResult>;
  execute(sql: string): Promise<number>;
}

export declare class QueryBuilder {
  constructor(client: Client);
  select(...cols: string[]): this;
  from(table: string): this;
  where(clause: string): this;
  join(table: string, on: string): this;
  leftJoin(table: string, on: string): this;
  groupBy(...cols: string[]): this;
  having(clause: string): this;
  orderBy(col: string, direction?: string): this;
  limit(n: number): this;
  offset(n: number): this;
  build(): string;
  exec(): Promise<QueryResult>;
}
