import baradb_sqlite

var db = open("127.0.0.1:9472", "", "", "default")

db.exec(sql"CREATE TABLE test_adapter (id INT PRIMARY KEY, name STRING)")
db.exec(sql"INSERT INTO test_adapter (id, name) VALUES (1, 'hello')")
db.exec(sql"INSERT INTO test_adapter (id, name) VALUES (2, 'world')")

let rows = db.getAllRows(sql"SELECT * FROM test_adapter")
echo "All rows: ", rows

let row = db.getRow(sql"SELECT * FROM test_adapter WHERE id = 1")
echo "Row 1: ", row

let val = db.getValue(sql"SELECT name FROM test_adapter WHERE id = 2")
echo "Value: ", val

let cnt = db.getValue(sql"SELECT count(*) FROM test_adapter")
echo "Count: ", cnt

db.close()
