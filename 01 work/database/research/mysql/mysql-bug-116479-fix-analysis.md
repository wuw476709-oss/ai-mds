# MySQL Bug #116479 修复分析：JSON 非法默认值与 `SHOW CREATE TABLE`

## 结论

MySQL 社区 Bug [#116479](https://bugs.mysql.com/bug.php?id=116479) 对应 Oracle 内部编号 **Bug #37219226**，官方在 [MySQL 9.3.0 Release Notes](https://dev.mysql.com/doc/relnotes/mysql/9.7/en/news-9-3-0.html) 中将其列为已修复。

9.3.0 的修复不是简单地在所有模式下禁止 `JSON DEFAULT ''`，而是先解决 `SHOW CREATE TABLE` 生成的 DDL 无法在其他 MySQL 实例重放的问题：对于历史上在非严格模式下接受的非法 JSON 默认值，输出时将 `DEFAULT` 子句注释掉，并产生 warning。

真正从建表入口禁止 JSON 常量默认值（包括非严格模式）的后续修改直到 MySQL 9.5.0 才进入发布版本。

## 问题现象

在非严格模式下，旧版本允许执行：

```sql
SET SESSION sql_mode = 'NO_ENGINE_SUBSTITUTION';

CREATE TABLE t0 (
  a INT,
  b JSON NOT NULL DEFAULT ''
);
```

创建过程中会产生 `ER_BLOB_CANT_HAVE_DEFAULT` warning，但表仍能创建。空字符串默认值在内部又会表现为 JSON `null`，导致旧版本的 `SHOW CREATE TABLE` 输出类似：

```sql
CREATE TABLE `t0` (
  `a` int DEFAULT NULL,
  `b` json NOT NULL DEFAULT 'null'
);
```

将这段 DDL 交给 mysqldump、mydumper 或其他 schema 迁移工具，再在另一台 mysqld 上执行时，会被拒绝：

```text
ERROR 1101 (42000): BLOB, TEXT, GEOMETRY or JSON column 'b'
can't have a default value
```

这造成一种不一致：源实例能创建表，但其 `SHOW CREATE TABLE` 输出无法用于重建同一张表。

## MySQL 9.3.0 对应提交

以下四个提交均位于 `mysql-9.3.0` tag 的历史中。

### 1. 核心修复：注释非法 JSON 默认值

- Commit: [`c116439b28c5548aaafcb7270a9f5ca71f31ed8d`](https://github.com/mysql/mysql-server/commit/c116439b28c5548aaafcb7270a9f5ca71f31ed8d)
- 主要文件：`sql/sql_show.cc`
- Commit message: `Bug#37219226 json value unexpected with default ''[1,noclose]`

该提交给 `print_default_clause()` 增加了 `as_a_comment` 输出参数：

```cpp
static bool print_default_clause(THD *thd, Field *field,
                                 String *def_value, bool quoted,
                                 bool *as_a_comment);
```

当字段类型为 JSON，并发现一个原本不应存在的非 NULL 常量默认值时，代码会：

1. 产生 `ER_BLOB_CANT_HAVE_DEFAULT` warning；
2. 将 `as_a_comment` 设为 `true`；
3. 在 `SHOW CREATE TABLE` 中把 `DEFAULT` 子句包在注释里。

关键逻辑可概括为：

```cpp
if (field_type == MYSQL_TYPE_JSON) {
  push_warning_printf(
      thd, Sql_condition::SL_WARNING,
      ER_BLOB_CANT_HAVE_DEFAULT,
      ER_THD(thd, ER_BLOB_CANT_HAVE_DEFAULT),
      field->field_name);

  if (as_a_comment != nullptr) *as_a_comment = true;
}
```

输出 DDL 时：

```cpp
if (as_a_comment) packet->append(STRING_WITH_LEN(" /* "));
packet->append(STRING_WITH_LEN(" DEFAULT "));
packet->append(def_value.ptr(), def_value.length(), system_charset_info);
if (as_a_comment) packet->append(STRING_WITH_LEN(" */ "));
```

修复后的输出变为：

```sql
CREATE TABLE `t0` (
  `a` int DEFAULT NULL,
  `b` json NOT NULL /* DEFAULT 'null' */
);
```

注释后的 DDL 可以在另一台 MySQL 上执行，从而解决 schema dump 无法重放的问题。

### 2. 默认值标志位修正

- Commit: [`dc1d399c9d701f4fe135a73f5663378b81b00fd4`](https://github.com/mysql/mysql-server/commit/dc1d399c9d701f4fe135a73f5663378b81b00fd4)
- 主要文件：`sql/create_field.cc`
- Commit message: `Bug#37219226 json value unexpected with default ''[2, noclose]`

该提交在降级非法 BLOB 默认值时增加：

```cpp
if (fld_type != MYSQL_TYPE_JSON) flags |= NO_DEFAULT_VALUE_FLAG;
```

它将普通 BLOB/TEXT 与当时仍需兼容处理的 JSON 行为区分开，并同步更新相关测试预期，使没有合法默认值的 BLOB/TEXT 在 INSERT 时正确产生 `Field ... doesn't have a default value` warning。

### 3. 回归测试

- Commit: [`dc2b5eada25a4dcbc58ea6397b0e488b29506818`](https://github.com/mysql/mysql-server/commit/dc2b5eada25a4dcbc58ea6397b0e488b29506818)
- 文件：
  - `mysql-test/suite/json/t/json_innodb.test`
  - `mysql-test/suite/json/r/json_innodb.result`

覆盖内容包括：

- 严格模式下 BLOB、GEOMETRY、JSON 常量默认值应报错；
- 非严格模式下 BLOB/JSON 空字符串默认值的兼容行为；
- `SHOW CREATE TABLE` 输出；
- 插入时的实际默认值；
- 显式 JSON `'null'` 默认值的错误处理。

### 4. NDB 测试结果更新

- Commit: [`c04c2f30a6c6861975c14de46f066207254d6c51`](https://github.com/mysql/mysql-server/commit/c04c2f30a6c6861975c14de46f066207254d6c51)
- 文件：`mysql-test/suite/ndb/r/ndb_native_default_support.result`

这是跟随核心行为变化而重新录制的 NDB 测试预期，不包含新的核心实现。

## 9.3 与后续版本的行为差异

### MySQL 9.3

9.3 的重点是让非法历史定义的 `SHOW CREATE TABLE` 结果可以安全重放：

```sql
`b` json NOT NULL /* DEFAULT 'null' */
```

也就是说，在 `NO_ENGINE_SUBSTITUTION` 等非严格模式下，`JSON DEFAULT ''` 当时仍可能以 warning 的方式被接受；9.3 通过注释默认值避免生成无法执行的 DDL。

### MySQL 9.5

后续提交：

- [`6e9dfc9a552fec995cbb029dc184127fb9530ab3`](https://github.com/mysql/mysql-server/commit/6e9dfc9a552fec995cbb029dc184127fb9530ab3)
- Commit message: `Bug#37219226 json value unexpected with default ''[next_version]`

该提交将 `MYSQL_TYPE_JSON` 从 BLOB 的非严格模式兼容分支中移出，改为与 GEOMETRY 一样，只要出现常量默认值就直接调用：

```cpp
my_error(ER_BLOB_CANT_HAVE_DEFAULT, MYF(0), fld_name);
```

因此下面的语句即使在非严格模式下也会失败：

```sql
CREATE TABLE t0 (b JSON NOT NULL DEFAULT '');
```

该提交不属于 9.3 或 9.4，首次包含在 `mysql-9.5.0` tag 中。

## 修复演进总结

| 版本 | 处理方式 | 结果 |
|---|---|---|
| 9.3 之前 | 非严格模式可能接受 `JSON DEFAULT ''`，但 `SHOW CREATE TABLE` 输出非法 `DEFAULT 'null'` | 导出的 DDL 无法重放 |
| 9.3 | 将非法 JSON 默认值输出为注释，并产生 warning | schema dump 可以重放 |
| 9.5 | 创建 JSON 常量默认值时直接报错 | 从建表入口消除非法定义 |

## 官方资料

- [MySQL Bug #116479：json value unexpected with default ''](https://bugs.mysql.com/bug.php?id=116479)
- [MySQL 9.3.0 Release Notes：JSON Notes](https://dev.mysql.com/doc/relnotes/mysql/9.7/en/news-9-3-0.html)
- [MySQL Server GitHub repository](https://github.com/mysql/mysql-server)
- [mysql-9.3.0 tag](https://github.com/mysql/mysql-server/tree/mysql-9.3.0)
- [mysql-9.5.0 tag](https://github.com/mysql/mysql-server/tree/mysql-9.5.0)

