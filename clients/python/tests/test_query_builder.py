"""
Unit tests for QueryBuilder — no running server required.
"""

import pytest
from baradb import Client, QueryBuilder


class TestQueryBuilder:
    def test_simple_select(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = qb.select("name", "age").from_("users").build()
        assert sql == "SELECT name, age FROM users"

    def test_select_all(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = qb.from_("users").build()
        assert sql == "SELECT * FROM users"

    def test_where_single(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = qb.select("name").from_("users").where("age > 18").build()
        assert sql == "SELECT name FROM users WHERE age > 18"

    def test_where_multiple(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = (
            qb.select("name")
            .from_("users")
            .where("age > 18")
            .where("active = true")
            .build()
        )
        assert sql == "SELECT name FROM users WHERE age > 18 AND active = true"

    def test_join(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = (
            qb.select("u.name", "o.total")
            .from_("users u")
            .join("orders o", "u.id = o.user_id")
            .build()
        )
        assert "JOIN orders o ON u.id = o.user_id" in sql

    def test_left_join(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = (
            qb.select("u.name", "o.total")
            .from_("users u")
            .left_join("orders o", "u.id = o.user_id")
            .build()
        )
        assert "LEFT JOIN orders o ON u.id = o.user_id" in sql

    def test_group_by_having(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = (
            qb.select("dept", "count(*)")
            .from_("employees")
            .group_by("dept")
            .having("count(*) > 5")
            .build()
        )
        assert "GROUP BY dept" in sql
        assert "HAVING count(*) > 5" in sql

    def test_order_by(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = qb.select("name").from_("users").order_by("name", "DESC").build()
        assert "ORDER BY name DESC" in sql

    def test_limit_offset(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = qb.select("name").from_("users").limit(10).offset(5).build()
        assert "LIMIT 10" in sql
        assert "OFFSET 5" in sql

    def test_full_complex_query(self):
        client = Client()
        qb = QueryBuilder(client)
        sql = (
            qb.select("u.name", "count(*) as cnt")
            .from_("users u")
            .left_join("orders o", "u.id = o.user_id")
            .where("u.age > 18")
            .group_by("u.name")
            .having("cnt > 3")
            .order_by("cnt", "DESC")
            .limit(50)
            .build()
        )
        assert sql.startswith("SELECT")
        assert "FROM users u" in sql
        assert "LEFT JOIN orders o ON u.id = o.user_id" in sql
        assert "WHERE u.age > 18" in sql
        assert "GROUP BY u.name" in sql
        assert "HAVING cnt > 3" in sql
        assert "ORDER BY cnt DESC" in sql
        assert "LIMIT 50" in sql
