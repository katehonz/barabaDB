"""
BaraDB Chat Message History — Conversation Buffer with RLS

Implements LangChain's BaseChatMessageHistory interface backed by BaraDB.
Supports multi-tenant isolation via tenant_id and user_id.

Usage:
    from baradb import Client, WireValue
    from baradb.chat_history import BaraDBChatHistory

    client = Client("localhost", 9472)
    await client.connect()

    history = BaraDBChatHistory(
        client=client,
        session_id="session-123",
        tenant_id="company-a",
        user_id="user-42",
    )

    # Add messages
    history.add_user_message("Hello, AI!")
    history.add_ai_message("Hello, how can I help?")

    # Retrieve conversation
    messages = history.messages
"""

import json
from datetime import datetime
from typing import Any, Dict, List, Optional


class BaraDBChatHistory:
    """
    Chat message history backed by BaraDB with multi-tenant RLS support.

    Stores conversations in a `chat_history` table with columns:
        id, session_id, role, content, metadata, tenant_id, user_id, created_at
    """

    def __init__(
        self,
        client: Any,
        session_id: str,
        table: str = "chat_history",
        tenant_id: Optional[str] = None,
        user_id: Optional[str] = None,
        max_messages: int = 1000,
    ):
        self.client = client
        self.session_id = session_id
        self.table = table
        self.tenant_id = tenant_id
        self.user_id = user_id
        self.max_messages = max_messages
        self._initialized = False

    async def _ensure_table(self):
        if self._initialized:
            return
        await self.client.query(
            f"""
            CREATE TABLE IF NOT EXISTS {self.table} (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                role TEXT,
                content TEXT,
                metadata TEXT,
                tenant_id TEXT,
                user_id TEXT,
                created_at TEXT
            )
            """
        )
        await self.client.query(
            f"CREATE INDEX IF NOT EXISTS idx_{self.table}_session "
            f"ON {self.table}(session_id) USING btree"
        )
        self._initialized = True

    def _build_session(self) -> Dict[str, str]:
        s = {"app.bara_chat_session": self.session_id}
        if self.tenant_id:
            s["app.tenant_id"] = self.tenant_id
        if self.user_id:
            s["app.user_id"] = self.user_id
        return s

    async def add_message(self, message: Any) -> None:
        await self._ensure_table()
        role = getattr(message, "type", "human")
        if role == "human":
            role = "user"
        content = getattr(message, "content", str(message))
        msg_id = f"{self.session_id}:{datetime.utcnow().timestamp()}"
        metadata = json.dumps(getattr(message, "additional_kwargs", {}) or {})
        created_at = datetime.utcnow().isoformat()

        for key, val in self._build_session().items():
            await self.client.query_params(
                f"SET {key} = $1", [self._wire_string(val)]
            )

        await self.client.query_params(
            f"INSERT INTO {self.table} (id, session_id, role, content, metadata, tenant_id, user_id, created_at) "
            f"VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            [
                self._wire_string(msg_id),
                self._wire_string(self.session_id),
                self._wire_string(role),
                self._wire_string(content),
                self._wire_string(metadata),
                self._wire_string(self.tenant_id or ""),
                self._wire_string(self.user_id or ""),
                self._wire_string(created_at),
            ],
        )

    def add_user_message(self, message: Any) -> None:
        import asyncio
        loop = asyncio.get_event_loop()
        if hasattr(message, "content"):
            content = message.content
        else:
            content = str(message)
        loop.run_until_complete(self._add_message_internal(content, "user"))

    def add_ai_message(self, message: Any) -> None:
        import asyncio
        loop = asyncio.get_event_loop()
        if hasattr(message, "content"):
            content = message.content
        else:
            content = str(message)
        loop.run_until_complete(self._add_message_internal(content, "ai"))

    async def _add_message_internal(self, content: str, role: str):
        await self._ensure_table()
        msg_id = f"{self.session_id}:{datetime.utcnow().timestamp()}"
        created_at = datetime.utcnow().isoformat()

        for key, val in self._build_session().items():
            await self.client.query_params(
                f"SET {key} = $1", [self._wire_string(val)]
            )

        await self.client.query_params(
            f"INSERT INTO {self.table} (id, session_id, role, content, tenant_id, user_id, created_at) "
            f"VALUES ($1, $2, $3, $4, $5, $6, $7)",
            [
                self._wire_string(msg_id),
                self._wire_string(self.session_id),
                self._wire_string(role),
                self._wire_string(content),
                self._wire_string(self.tenant_id or ""),
                self._wire_string(self.user_id or ""),
                self._wire_string(created_at),
            ],
        )

    async def get_messages(self) -> List[Any]:
        await self._ensure_table()
        class SimpleMessage:
            def __init__(self, role: str, content: str):
                self.type = "human" if role == "user" else role
                self.content = content
                self.additional_kwargs = {}

            def __repr__(self):
                return f"{self.type}: {self.content}"

        for key, val in self._build_session().items():
            await self.client.query_params(
                f"SET {key} = $1", [self._wire_string(val)]
            )

        result = await self.client.query_params(
            f"SELECT role, content FROM {self.table} "
            f"WHERE session_id = $1 "
            f"ORDER BY created_at ASC "
            f"LIMIT $2",
            [
                self._wire_string(self.session_id),
                self._wire_int(self.max_messages),
            ],
        )
        messages = []
        if result and hasattr(result, "rows"):
            for row in result.rows:
                role = row.get("role", "user")
                content = row.get("content", "")
                messages.append(SimpleMessage(role, content))

        return messages

    @property
    def messages(self) -> List[Any]:
        import asyncio
        loop = asyncio.get_event_loop()
        return loop.run_until_complete(self.get_messages())

    async def clear(self) -> None:
        await self._ensure_table()
        for key, val in self._build_session().items():
            await self.client.query_params(
                f"SET {key} = $1", [self._wire_string(val)]
            )
        await self.client.query_params(
            f"DELETE FROM {self.table} WHERE session_id = $1",
            [self._wire_string(self.session_id)],
        )

    async def get_session_summary(self, max_tokens: int = 2000) -> str:
        messages = await self.get_messages()
        parts = []
        total_chars = 0
        for msg in reversed(messages):
            text = f"{msg.type}: {getattr(msg, 'content', '')}"
            if total_chars + len(text) > max_tokens * 4:
                break
            parts.insert(0, text)
            total_chars += len(text)
        return "\n".join(parts)

    @staticmethod
    def _wire_string(val: str) -> Any:
        # Lazy import to avoid circular dependency
        from baradb import WireValue
        return WireValue.string(val)

    @staticmethod
    def _wire_int(val: int) -> Any:
        from baradb import WireValue
        return WireValue.int64(val)
