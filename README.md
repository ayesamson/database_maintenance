# SQL Server/Azure SQLDB Database Maintenance
## Scripts

| Script | Description |
|---------|-------------|
| StatisticsMaintenance.sql | Intelligent statistics maintenance using modification counters, table size, and adaptive sampling. |
| IndexMaintenance.sql | Intelligent index maintenance using fragmentation analysis, partition awareness, and adaptive rebuild/reorganize decisions. |

## Recommended Execution Order

1. Run **IndexMaintenance.sql**
2. Run **StatisticsMaintenance.sql**

When an index is rebuilt, SQL Server automatically updates statistics associated with that index using a full scan. Running StatisticsMaintenance afterward refreshes remaining statistics that were not updated by the index rebuild, including:

- Auto-created statistics (`_WA_Sys...`)
- User-created statistics
- Statistics not associated with an index

## Documentation

- [IndexMaintenance.md](IndexMaintenance.md)
- [StatisticsMaintenance.md](StatisticsMaintenance.md)

## License

MIT
