# SQL Server/Azure SQLDB Database Maintenance
Repository of utility scripts

It is recommended to defragment the indexes first. When an index is rebuilt, SQL Server automatically updates the statistics associated with that index using a full scan. Afterward, run UPDATE STATISTICS to refresh any remaining statistics that were not updated by the index rebuild, such as auto-created statistics (for example, _WA_Sys_00000003_4B7734FF) or user-created statistics that are not associated with an index.
