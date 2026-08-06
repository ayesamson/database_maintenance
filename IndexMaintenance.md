# Index Maintenance Script

## Overview

The **Index Maintenance Script** is a production-ready SQL Server maintenance utility designed to intelligently identify, prioritize, and maintain fragmented indexes within the current database. It is intended to be the companion script to the **Statistics Maintenance Script**, sharing the same execution framework, coding style, logging, and operational behavior.

The script is optimized for very large databases, including environments with hundreds of millions of rows, partitioned tables, and mixed OLTP/reporting workloads.

---

# Objectives

- Minimize unnecessary index maintenance.
- Reduce blocking and maintenance windows.
- Prioritize indexes with the greatest performance impact.
- Protect very large tables and partitions from unnecessary rebuilds.
- Produce predictable, repeatable maintenance operations.
- Maintain consistency with the Statistics Maintenance Script.

---

# Features

## Two Execution Modes

### Report Mode

```sql
@action = 0
```

Report mode performs analysis only.

The script:

- Collects fragmentation information.
- Scores candidate indexes.
- Determines the recommended maintenance operation.
- Generates the corresponding `ALTER INDEX` statement.
- Returns the candidate list.

No commands are executed.

No messages are printed.

No execution loop is entered.

---

### Execute Mode

```sql
@action = 1
```

Execution mode processes one index at a time.

Progress is displayed in real time using the same format as the Statistics Maintenance Script.

Example:

```text
Starting: (1 of 64) ALTER INDEX [Travel_Cruise].[SailingPriceDetail] [IX_SailingPriceDetail_Supplier]
REBUILD PARTITION = 8
WITH (SORT_IN_TEMPDB = ON, MAXDOP = 2);

Completed.
StartTime: (2026-08-06 01:39:07.830)
EndTime:   (2026-08-06 01:41:09.200)
Duration:  (0:00:02:02)
--------------------------------------------------------------------------------------------------------------
```

---

# Candidate Discovery

The script analyzes indexes using SQL Server metadata and Dynamic Management Views (DMVs), including:

- `sys.indexes`
- `sys.partitions`
- `sys.dm_db_partition_stats`
- `sys.dm_db_index_usage_stats`
- `sys.dm_db_index_physical_stats`
- `sys.objects`
- `sys.schemas`

Only eligible rowstore indexes are considered.

---

# Automatic Exclusions

The following objects are skipped automatically:

- Disabled indexes
- Hypothetical indexes
- System tables
- Memory-optimized tables
- Schema-locked objects
- Small indexes below the configured page threshold

---

# Fragmentation Analysis

Each index (or partition) is evaluated using:

- Average fragmentation percentage
- Page count
- Partition row count
- Average page density
- Fragment count
- Average fragment size

---

# Usage Analysis

Index usage statistics are incorporated into the scoring model.

Metrics include:

- User seeks
- User scans
- User lookups
- User updates
- Total read activity

Frequently accessed indexes receive higher maintenance priority.

---

# Partition Awareness

Maintenance decisions are made at the **partition level** whenever possible.

Instead of treating an entire partitioned table as a single object, each partition is evaluated independently.

Benefits include:

- Smaller maintenance operations
- Reduced log generation
- Shorter execution times
- Lower blocking risk

---

# Large Partition Protection

Very large partitions receive additional safeguards.

For example:

| Partition | Rows | Recommended Action |
|-----------|------:|--------------------|
| 4 | 4 million | Rebuild |
| 12 | 180 million | Reorganize |

This prevents accidental rebuilds of extremely large partitions during normal maintenance.

---

# Intelligent Scoring

Each candidate receives an urgency score based on:

- Fragmentation level
- Page count
- Partition size
- Read activity
- Update activity
- Compression
- Fill factor

Only the highest priority indexes are processed.

---

# Maintenance Decisions

The script automatically recommends one of the following:

- None
- Reorganize
- Rebuild

Thresholds are fully configurable.

---

# Command Generation

Exactly one maintenance command is generated for each candidate.

Examples:

```sql
ALTER INDEX [IX_Order]
ON [Sales].[Order]
REORGANIZE;
```

```sql
ALTER INDEX [IX_Order]
ON [Sales].[Order]
REBUILD;
```

```sql
ALTER INDEX [IX_Order]
ON [Sales].[Order]
REBUILD PARTITION = 12;
```

---

# Adaptive MAXDOP

`MAXDOP` is automatically selected based on index size.

Example defaults:

| Index Size | MAXDOP |
|------------|--------|
| Small | 1 |
| Medium | 2 |
| Large | 4 |

Values are configurable.

---

# Online Maintenance

When supported by the SQL Server edition and operation, the script supports:

- Online rebuilds
- Resumable rebuilds
- WAIT_AT_LOW_PRIORITY

These features are configurable.

---

# Deadlock Retry

Deadlocks are automatically retried once before the operation is marked as failed.

This behavior mirrors the Statistics Maintenance Script.

---

# Lock Timeout

The script applies a configurable `LOCK_TIMEOUT` to avoid waiting indefinitely on schema changes.

Timed-out operations are recorded as:

```text
SKIPPED_LOCK_TIMEOUT
```

allowing the maintenance run to continue.

---

# Execution Logging

Execution history is captured in:

```text
#ProcessedIndexes
```

Columns include:

- Id
- DatabaseName
- SqlStatement
- StartTime
- EndTime
- Duration
- Status
- ErrorNumber
- ErrorMessage

---

# Output

## Report Mode

Returns:

```text
#tempIndexes
```

Only the candidate list is returned.

No messages are written to the Messages tab.

---

## Execute Mode

Returns:

```text
#ProcessedIndexes
```

after execution (when enabled).

---

# Design Philosophy

This script is not intended to replace comprehensive maintenance frameworks such as Ola Hallengren's maintenance solution.

Instead, it is designed to be the **index maintenance counterpart** to the existing Statistics Maintenance Script, providing:

- Transparent T-SQL implementation
- Intelligent scoring
- Consistent execution framework
- Predictable logging
- Production-safe maintenance
- Easy customization
- Source-control friendly code

The goal is for both maintenance scripts to share the same structure, coding style, execution model, and operational behavior, making them easier to understand, maintain, and extend over time.
