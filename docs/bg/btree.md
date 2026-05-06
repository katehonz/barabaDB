# B-Tree Индекс

Подредена индексна структура за ефективни диапазонни заявки.

## Употреба

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Функции

- Подредени ключ-стойност двойки
- Диапазонни заявки (BETWEEN, >, <, >=, <=)
- Префиксни сканирания
- Конфигурируем размер на страницата