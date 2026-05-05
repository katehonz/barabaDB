// Package baradb provides a Go client for BaraDB database.
//
// Usage:
//
//	client, err := baradb.Connect("localhost", 5432)
//	if err != nil { log.Fatal(err) }
//	defer client.Close()
//
//	result, err := client.Query("SELECT name FROM users WHERE age > 18")
//	for _, row := range result.Rows {
//	    fmt.Println(row["name"])
//	}
package baradb

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"
)

// FieldKind constants for wire protocol
const (
	FkNull    = 0x00
	FkBool    = 0x01
	FkInt8    = 0x02
	FkInt16   = 0x03
	FkInt32   = 0x04
	FkInt64   = 0x05
	FkFloat32 = 0x06
	FkFloat64 = 0x07
	FkString  = 0x08
	FkBytes   = 0x09
	FkArray   = 0x0A
	FkObject  = 0x0B
	FkVector  = 0x0C
)

// MsgKind constants
const (
	MkQuery    = 0x02
	MkBatch    = 0x05
	MkClose    = 0x07
	MkPing     = 0x08
	MkReady    = 0x81
	MkData     = 0x82
	MkComplete = 0x83
	MkError    = 0x84
	MkPong     = 0x88
)

// Config holds connection configuration
type Config struct {
	Host     string
	Port     int
	Database string
	Username string
	Password string
	Timeout  time.Duration
}

// DefaultConfig returns default configuration
func DefaultConfig() Config {
	return Config{
		Host:     "127.0.0.1",
		Port:     5432,
		Database: "default",
		Username: "admin",
		Password: "",
		Timeout:  30 * time.Second,
	}
}

// QueryResult holds query results
type QueryResult struct {
	Columns      []string
	Rows         []map[string]string
	RowCount     int
	AffectedRows int
}

// Client is the BaraDB database client
type Client struct {
	config    Config
	conn      net.Conn
	connected bool
	mu        sync.Mutex
	requestID uint32
}

// Connect creates a new connection to BaraDB
func Connect(host string, port int) (*Client, error) {
	config := DefaultConfig()
	config.Host = host
	config.Port = port
	return ConnectWithConfig(config)
}

// ConnectWithConfig creates a connection with custom config
func ConnectWithConfig(config Config) (*Client, error) {
	addr := fmt.Sprintf("%s:%d", config.Host, config.Port)
	conn, err := net.DialTimeout("tcp", addr, config.Timeout)
	if err != nil {
		return nil, fmt.Errorf("connect failed: %w", err)
	}
	return &Client{config: config, conn: conn, connected: true}, nil
}

// Close closes the connection
func (c *Client) Close() error {
	c.connected = false
	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

// IsConnected returns connection status
func (c *Client) IsConnected() bool {
	return c.connected
}

// Query executes a BaraQL query
func (c *Client) Query(sql string) (*QueryResult, error) {
	if !c.connected {
		return nil, fmt.Errorf("not connected")
	}

	payload := encodeString(sql)
	payload = append(payload, 0x00) // ResultFormat.BINARY
	msg := buildMessage(MkQuery, c.nextID(), payload)

	_, err := c.conn.Write(msg)
	if err != nil {
		return nil, fmt.Errorf("send failed: %w", err)
	}

	// Read response header
	header := make([]byte, 12)
	_, err = io.ReadFull(c.conn, header)
	if err != nil {
		return nil, fmt.Errorf("read header failed: %w", err)
	}

	kind := binary.BigEndian.Uint32(header[0:4])
	length := binary.BigEndian.Uint32(header[4:8])

	if kind == MkError && length > 0 {
		payload := make([]byte, length)
		io.ReadFull(c.conn, payload)
		return nil, fmt.Errorf("query error")
	}

	if length > 0 {
		payload := make([]byte, length)
		io.ReadFull(c.conn, payload)
	}

	return &QueryResult{}, nil
}

// Execute executes a statement (INSERT, UPDATE, DELETE)
func (c *Client) Execute(sql string) (int, error) {
	result, err := c.Query(sql)
	if err != nil {
		return 0, err
	}
	return result.AffectedRows, nil
}

// Ping tests the connection
func (c *Client) Ping() error {
	msg := buildMessage(MkPing, c.nextID(), []byte{})
	_, err := c.conn.Write(msg)
	return err
}

func (c *Client) nextID() uint32 {
	c.mu.Lock()
	c.requestID++
	id := c.requestID
	c.mu.Unlock()
	return id
}

// QueryBuilder provides fluent query construction
type QueryBuilder struct {
	client   *Client
	cols     []string
	table    string
	where    []string
	joins    []string
	groupBy  []string
	having   string
	orderBy  []string
	limit    int
	offset   int
}

// NewQueryBuilder creates a new query builder
func (c *Client) QueryBuilder() *QueryBuilder {
	return &QueryBuilder{client: c}
}

func (qb *QueryBuilder) Select(cols ...string) *QueryBuilder {
	qb.cols = append(qb.cols, cols...)
	return qb
}

func (qb *QueryBuilder) From(table string) *QueryBuilder {
	qb.table = table
	return qb
}

func (qb *QueryBuilder) Where(clause string) *QueryBuilder {
	qb.where = append(qb.where, clause)
	return qb
}

func (qb *QueryBuilder) Join(table, on string) *QueryBuilder {
	qb.joins = append(qb.joins, fmt.Sprintf("JOIN %s ON %s", table, on))
	return qb
}

func (qb *QueryBuilder) LeftJoin(table, on string) *QueryBuilder {
	qb.joins = append(qb.joins, fmt.Sprintf("LEFT JOIN %s ON %s", table, on))
	return qb
}

func (qb *QueryBuilder) GroupBy(cols ...string) *QueryBuilder {
	qb.groupBy = append(qb.groupBy, cols...)
	return qb
}

func (qb *QueryBuilder) Having(clause string) *QueryBuilder {
	qb.having = clause
	return qb
}

func (qb *QueryBuilder) OrderBy(col, dir string) *QueryBuilder {
	qb.orderBy = append(qb.orderBy, fmt.Sprintf("%s %s", col, dir))
	return qb
}

func (qb *QueryBuilder) Limit(n int) *QueryBuilder {
	qb.limit = n
	return qb
}

func (qb *QueryBuilder) Offset(n int) *QueryBuilder {
	qb.offset = n
	return qb
}

// Build returns the SQL string
func (qb *QueryBuilder) Build() string {
	sql := "SELECT "
	if len(qb.cols) > 0 {
		sql += strings.Join(qb.cols, ", ")
	} else {
		sql += "*"
	}
	sql += " FROM " + qb.table
	for _, j := range qb.joins {
		sql += " " + j
	}
	if len(qb.where) > 0 {
		sql += " WHERE " + strings.Join(qb.where, " AND ")
	}
	if len(qb.groupBy) > 0 {
		sql += " GROUP BY " + strings.Join(qb.groupBy, ", ")
	}
	if qb.having != "" {
		sql += " HAVING " + qb.having
	}
	if len(qb.orderBy) > 0 {
		sql += " ORDER BY " + strings.Join(qb.orderBy, ", ")
	}
	if qb.limit > 0 {
		sql += fmt.Sprintf(" LIMIT %d", qb.limit)
	}
	if qb.offset > 0 {
		sql += fmt.Sprintf(" OFFSET %d", qb.offset)
	}
	return sql
}

// Exec executes the built query
func (qb *QueryBuilder) Exec() (*QueryResult, error) {
	return qb.client.Query(qb.Build())
}

func buildMessage(kind uint32, reqID uint32, payload []byte) []byte {
	msg := make([]byte, 12+len(payload))
	binary.BigEndian.PutUint32(msg[0:4], kind)
	binary.BigEndian.PutUint32(msg[4:8], uint32(len(payload)))
	binary.BigEndian.PutUint32(msg[8:12], reqID)
	copy(msg[12:], payload)
	return msg
}

func encodeString(s string) []byte {
	data := []byte(s)
	result := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(result[0:4], uint32(len(data)))
	copy(result[4:], data)
	return result
}
