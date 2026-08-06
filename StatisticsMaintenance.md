# Statistics Maintenance Script

## Overview

The **Statistics Maintenance Script** is a production-ready SQL Server maintenance utility that intelligently identifies and updates stale statistics based on table size, modification activity, and historical sampling rates. Rather than updating every statistic indiscriminately, the script ranks statistics by urgency and generates the most appropriate `UPDATE STATISTICS` command using either **FULLSCAN** or an adaptive sampling percentage. The script supports both reporting and execution modes, making it suitable for scheduled maintenance as well as on-demand analysis. :contentReference[oaicite:0]{index=0}

---

# Objectives

- Minimize unnecessary statistics updates.
- Prioritize statistics with the greatest impact on query optimization.
- Reduce maintenance windows by using adaptive sampling.
- Avoid excessive full scans on very large tables.
- Produce repeatable and predictable maintenance operations.
- Provide transparent reporting before execution.

---

# Features

## Two Execution Modes

### Report Mode

```sql
@action = 0
```

Report mode analyzes the database and returns the recommended maintenance actions without executing any updates.

The script:

- Collects statistics metadata.
- Calculates modification percentages.
- Scores statistics by urgency.
- Recommends sampling levels.
- Generates the corresponding `UPDATE STATISTICS` statement.

---

### Execute Mode

```sql
@action = 1
```

Execution mode processes one statistics object at a time.

Progress is displayed in real time.

Example:

```text
Starting: (1 of 64) UPDATE STATISTICS [Sales].[Orders] [IX_OrderDate]
WITH SAMPLE 50 PERCENT, MAXDOP = 2;

Completed.
StartTime: (2026-08-06 01:39:07.830)
EndTime:   (2026-08-06 01:41:09.200)
Duration:  (0:00:02:02)
--------------------------------------------------------------------------------------------------------------
```

Execution details are logged for every processed statistic. :contentReference[oaicite:1]{index=1}

---

# Candidate Discovery

The script gathers metadata from SQL Server system catalog views and Dynamic Management Views (DMVs), including:

- `sys.stats`
- `sys.objects`
- `sys.schemas`
- `sys.partitions`
- `sys.indexes`
- `sys.dm_db_stats_properties`
- `sys.dm_tran_locks`

Only user-table statistics are considered. Hypothetical indexes and schema-locked objects are excluded automatically. :contentReference[oaicite:2]{index=2}

---

# Intelligent Scoring

Each statistics object is evaluated using multiple factors, including:

- Table row count
- Modification counter
- Percentage of modified rows
- Previous sampling ratio
- Filtered statistics
- Days since the last update

These metrics are combined into an urgency score that determines maintenance priority. :contentReference[oaicite:3]{index=3}

---

# Adaptive Sampling

The script automatically determines the most appropriate update method based on table size and modification activity.

Possible recommendations include:

- `FULLSCAN`
- `SAMPLE 50 PERCENT`
- `SAMPLE 20 PERCENT`
- `SAMPLE 10 PERCENT`

Smaller tables typically receive a full scan, while larger tables use progressively lower sampling percentages to reduce maintenance overhead. :contentReference[oaicite:4]{index=4}

---

# Intelligent Deduplication

For smaller tables where a table-level `UPDATE STATISTICS ... WITH FULLSCAN` is more efficient, duplicate commands are eliminated so that only a single update is generated per table.

This minimizes redundant work while ensuring all associated statistics are refreshed. :contentReference[oaicite:5]{index=5}

---

# Adaptive MAXDOP

The script automatically adjusts the `MAXDOP` option according to table size.

Example defaults:

| Table Size | MAXDOP |
|------------|--------|
| Small | 1 |
| Medium | 2 |
| Large | 4 |

---

# Deadlock Retry

Execution automatically retries once when a deadlock occurs.

This improves resilience during busy production workloads without terminating the entire maintenance run. :contentReference[oaicite:6]{index=6}

---

# Lock Timeout Protection

The script applies a configurable `LOCK_TIMEOUT` before executing each command.

If a schema lock prevents execution, the operation is skipped and recorded rather than blocking the remainder of the maintenance job. :contentReference[oaicite:7]{index=7}

---

# Execution Logging

Execution history is stored in:

```text
#ProcessedStats
```

Each processed command records:

- Id
- DatabaseName
- SQL Statement
- StartTime
- EndTime
- Duration
- Status
- ErrorNumber
- ErrorMessage

This provides a complete audit trail for every maintenance run. :contentReference[oaicite:8]{index=8}

---

# Output

## Report Mode

Returns:

```text
#tempStats
```

containing:

- Statistics metadata
- Modification information
- Recommended sampling method
- Generated `UPDATE STATISTICS` command
- Urgency score

## Execute Mode

Returns:

```text
#ProcessedStats
```

summarizing the outcome of each executed command.

---

# Design Philosophy

Rather than refreshing every statistic on a fixed schedule, this script focuses maintenance effort where it provides the greatest benefit. By combining modification activity, table size, historical sampling information, and adaptive execution strategies, it reduces unnecessary work while ensuring that the most impactful statistics remain current.

The script is designed to be transparent, configurable, source-control friendly, and suitable for both SQL Server and Azure SQL Database environments. It also serves as the companion script to **IndexMaintenance.sql**, sharing the same execution framework, coding style, and operational behavior.
