/*
    Index Maintenance Script
    Copyright (c) 2026 ayesamson

    Licensed under the MIT License.
    See the LICENSE file in the project root for license information.

    Notes:
      - Runs in the current database only.
      - Maintains enabled rowstore indexes (clustered and nonclustered).
      - Evaluates and maintains individual partitions.
      - @action = 0 is report/dry-run mode; @action = 1 executes commands.
      - ONLINE and RESUMABLE are disabled by default for broad compatibility.
*/
SET NOCOUNT ON;
BEGIN
    DROP TABLE IF EXISTS #tempIndexes;
    DROP TABLE IF EXISTS #ProcessedIndexes;

    DECLARE
          @action BIT = 0
        , @showResults BIT = 1
        , @tableName SYSNAME = NULL -- NULL for all tables, or 'TableName' / 'Schema.TableName'
        , @scanMode VARCHAR(10) = 'LIMITED' -- LIMITED, SAMPLED, or DETAILED
        , @minPageCount BIGINT = 1000
        , @reorganizeThreshold DECIMAL(9,4) = 10.0
        , @rebuildThreshold DECIMAL(9,4) = 30.0
        , @criticalFragmentationThreshold DECIMAL(9,4) = 50.0
        , @topN INT = 200
        , @sortInTempdb BIT = 1
        , @onlineRebuild BIT = 1
        , @resumableRebuild BIT = 0
        , @lowPriorityWaitMinutes INT = 5
        , @maxDopSmall INT = 1
        , @maxDopMedium INT = 2
        , @maxDopLarge INT = 4
        , @mediumPageCount BIGINT = 100000
        , @largePageCount BIGINT = 1000000
        , @maxRetries INT = 1
        , @retryDelay VARCHAR(8) = '00:00:10'
        , @loopCount INT = 1
        , @totalCount INT = 0
        , @sqlCommand NVARCHAR(MAX)
        , @startTime DATETIME2(3)
        , @endTime DATETIME2(3)
        , @duration VARCHAR(50)
        , @message NVARCHAR(2047)
        , @diffSec BIGINT;

    IF UPPER(@scanMode) NOT IN ('LIMITED', 'SAMPLED', 'DETAILED')
        THROW 50001, '@scanMode must be LIMITED, SAMPLED, or DETAILED.', 1;

    IF @reorganizeThreshold < 0
       OR @rebuildThreshold <= @reorganizeThreshold
       OR @criticalFragmentationThreshold < @rebuildThreshold
        THROW 50002, 'Fragmentation thresholds are invalid.', 1;

    IF @resumableRebuild = 1 AND @onlineRebuild = 0
        THROW 50003, 'RESUMABLE rebuild requires ONLINE rebuild.', 1;

    ;WITH physical_stats AS
    (
        SELECT
              ips.object_id
            , ips.index_id
            , ips.partition_number
            , ips.avg_fragmentation_in_percent
            , ips.page_count
            , ips.avg_page_space_used_in_percent
            , ips.fragment_count
            , ips.avg_fragment_size_in_pages
        FROM sys.dm_db_index_physical_stats
        (
              DB_ID()
            , NULL
            , NULL
            , NULL
            , @scanMode
        ) AS ips
        WHERE ips.index_id > 0
          AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
          AND ips.index_level = 0
    ),
    index_base AS
    (
        SELECT
              ps.object_id
            , ps.index_id
            , ps.partition_number
            , sch.name AS schema_name
            , o.name AS table_name
            , i.name AS index_name
            , i.type_desc AS index_type
            , i.is_unique
            , i.is_primary_key
            , i.is_unique_constraint
            , i.fill_factor
            , i.allow_page_locks
            , i.allow_row_locks
            , CONVERT(BIT, CASE WHEN pscheme.data_space_id IS NOT NULL THEN 1 ELSE 0 END) AS is_partitioned
            , p.data_compression_desc
            , ps.page_count
            , ps.avg_fragmentation_in_percent
            , ps.avg_page_space_used_in_percent
            , ps.fragment_count
            , ps.avg_fragment_size_in_pages
            , COALESCE(us.user_seeks, 0) AS user_seeks
            , COALESCE(us.user_scans, 0) AS user_scans
            , COALESCE(us.user_lookups, 0) AS user_lookups
            , COALESCE(us.user_updates, 0) AS user_updates
            , COALESCE(us.user_seeks, 0)
              + COALESCE(us.user_scans, 0)
              + COALESCE(us.user_lookups, 0) AS total_reads
        FROM physical_stats AS ps
        INNER JOIN sys.indexes AS i
            ON i.object_id = ps.object_id
           AND i.index_id = ps.index_id
        LEFT JOIN sys.partition_schemes AS pscheme
            ON pscheme.data_space_id = i.data_space_id
        INNER JOIN sys.objects AS o
            ON o.object_id = ps.object_id
        INNER JOIN sys.schemas AS sch
            ON sch.schema_id = o.schema_id
        INNER JOIN sys.partitions AS p
            ON p.object_id = ps.object_id
           AND p.index_id = ps.index_id
           AND p.partition_number = ps.partition_number
        LEFT JOIN sys.dm_db_index_usage_stats AS us
            ON us.database_id = DB_ID()
           AND us.object_id = ps.object_id
           AND us.index_id = ps.index_id
        WHERE o.type = 'U'
          AND o.is_ms_shipped = 0
          AND OBJECTPROPERTY(o.object_id, 'IsUserTable') = 1
          AND i.type IN (1, 2)
          AND i.is_disabled = 0
          AND i.is_hypothetical = 0
          AND i.name IS NOT NULL
          AND ps.page_count >= @minPageCount
          AND NOT EXISTS
          (
              SELECT 1
              FROM sys.tables AS t
              WHERE t.object_id = o.object_id
                AND t.is_memory_optimized = 1
          )
          AND NOT EXISTS
          (
              SELECT 1
              FROM sys.dm_tran_locks AS tl
              WHERE tl.resource_database_id = DB_ID()
                AND tl.resource_type = 'OBJECT'
                AND tl.request_mode = 'Sch-M'
                AND tl.request_status = 'GRANT'
                AND tl.resource_associated_entity_id = o.object_id
          )
          AND
          (
                 @tableName IS NULL
              OR o.name = @tableName
              OR CONCAT(sch.name, '.', o.name) = @tableName
          )
    ),
    scored AS
    (
        SELECT
              ib.*
            , CASE
                  WHEN ib.avg_fragmentation_in_percent >= @criticalFragmentationThreshold THEN 'CRITICAL'
                  WHEN ib.avg_fragmentation_in_percent >= @rebuildThreshold THEN 'HIGH'
                  WHEN ib.avg_fragmentation_in_percent >= @reorganizeThreshold THEN 'MEDIUM'
                  ELSE 'WATCH'
              END AS action_bucket
            , CASE
                  WHEN ib.avg_fragmentation_in_percent >= @rebuildThreshold THEN 'REBUILD'
                  WHEN ib.avg_fragmentation_in_percent >= @reorganizeThreshold
                       AND ib.allow_page_locks = 1 THEN 'REORGANIZE'
                  WHEN ib.avg_fragmentation_in_percent >= @reorganizeThreshold
                       AND ib.allow_page_locks = 0 THEN 'REBUILD'
                  ELSE 'NONE'
              END AS recommended_action
            , CONVERT(INT,
                  CASE
                      WHEN ib.avg_fragmentation_in_percent >= 80 THEN 100
                      WHEN ib.avg_fragmentation_in_percent >= 50 THEN 85
                      WHEN ib.avg_fragmentation_in_percent >= 30 THEN 70
                      WHEN ib.avg_fragmentation_in_percent >= 20 THEN 50
                      WHEN ib.avg_fragmentation_in_percent >= 10 THEN 30
                      ELSE 0
                  END
                  + CASE
                      WHEN ib.page_count >= 10000000 THEN 40
                      WHEN ib.page_count >= 1000000 THEN 30
                      WHEN ib.page_count >= 100000 THEN 20
                      WHEN ib.page_count >= 10000 THEN 10
                      ELSE 0
                    END
                  + CASE
                      WHEN ib.total_reads >= 1000000 THEN 20
                      WHEN ib.total_reads >= 100000 THEN 15
                      WHEN ib.total_reads >= 10000 THEN 10
                      WHEN ib.total_reads > 0 THEN 5
                      ELSE 0
                    END
              ) AS urgency_score
        FROM index_base AS ib
    ),
    candidates AS
    (
        SELECT
              s.*
            , CASE
                  WHEN s.recommended_action = 'REORGANIZE'
                      THEN
                          N'ALTER INDEX ' + QUOTENAME(s.index_name)
                          + N' ON ' + QUOTENAME(s.schema_name) + N'.' + QUOTENAME(s.table_name)
                          + CASE
                                WHEN s.is_partitioned = 1
                                    THEN N' REORGANIZE PARTITION = '
                                         + CONVERT(NVARCHAR(20), s.partition_number)
                                ELSE N' REORGANIZE'
                            END
                          + N' WITH (LOB_COMPACTION = ON);'
                  WHEN s.recommended_action = 'REBUILD'
                      THEN
                          N'ALTER INDEX ' + QUOTENAME(s.index_name)
                          + N' ON ' + QUOTENAME(s.schema_name) + N'.' + QUOTENAME(s.table_name)
                          + CASE
                                WHEN s.is_partitioned = 1
                                    THEN N' REBUILD PARTITION = '
                                         + CONVERT(NVARCHAR(20), s.partition_number)
                                ELSE N' REBUILD'
                            END
                          + N' WITH ('
                          + N'SORT_IN_TEMPDB = '
                          + CASE WHEN @sortInTempdb = 1 THEN N'ON' ELSE N'OFF' END
                          + N', MAXDOP = '
                          + CONVERT
                            (
                                NVARCHAR(10),
                                CASE
                                    WHEN s.page_count < @mediumPageCount THEN @maxDopSmall
                                    WHEN s.page_count < @largePageCount THEN @maxDopMedium
                                    ELSE @maxDopLarge
                                END
                            )
                          + CASE
                                WHEN @onlineRebuild = 1
                                    THEN N', ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = '
                                         + CONVERT(NVARCHAR(10), @lowPriorityWaitMinutes)
                                         + N' MINUTES, ABORT_AFTER_WAIT = SELF))'
                                ELSE N', ONLINE = OFF'
                            END
                          + CASE
                                WHEN @resumableRebuild = 1
                                    THEN N', RESUMABLE = ON'
                                ELSE N''
                            END
                          + N');'
                  ELSE NULL
              END AS generated_maintenance_command
        FROM scored AS s
        WHERE s.recommended_action IN ('REORGANIZE', 'REBUILD')
    ),
    ranked AS
    (
        SELECT TOP (@topN)
              c.*
        FROM candidates AS c
        WHERE c.generated_maintenance_command IS NOT NULL
        ORDER BY
              c.urgency_score DESC
            , c.avg_fragmentation_in_percent DESC
            , c.page_count DESC
            , c.total_reads DESC
            , c.schema_name
            , c.table_name
            , c.index_name
            , c.partition_number
    ),
    results AS
    (
        SELECT
              ROW_NUMBER() OVER
              (
                  ORDER BY
                        urgency_score DESC
                      , avg_fragmentation_in_percent DESC
                      , page_count DESC
                      , total_reads DESC
                      , schema_name
                      , table_name
                      , index_name
                      , partition_number
              ) AS row_num
            , CAST(N'' AS NVARCHAR(1)) AS [Indexes]
            , schema_name
            , table_name
            , index_name
            , index_type
            , partition_number
            , is_partitioned
            , data_compression_desc
            , page_count
            , CAST(avg_fragmentation_in_percent AS DECIMAL(9,2)) AS avg_fragmentation_pct
            , CAST(avg_page_space_used_in_percent AS DECIMAL(9,2)) AS avg_page_space_used_pct
            , fragment_count
            , CAST(avg_fragment_size_in_pages AS DECIMAL(19,2)) AS avg_fragment_size_pages
            , user_seeks
            , user_scans
            , user_lookups
            , user_updates
            , total_reads
            , allow_page_locks
            , allow_row_locks
            , fill_factor
            , action_bucket
            , recommended_action
            , urgency_score
            , generated_maintenance_command
        FROM ranked
    )
    SELECT
          CONVERT(INT, ROW_NUMBER() OVER (ORDER BY row_num)) AS Id
        , *
    INTO #tempIndexes
    FROM results;

    SET @totalCount = @@ROWCOUNT;

    CREATE TABLE #ProcessedIndexes
    (
          Id INT
        , DatabaseName SYSNAME
        , SqlStatement NVARCHAR(MAX)
        , StartTime DATETIME2(3)
        , EndTime DATETIME2(3)
        , Duration VARCHAR(50)
        , Status VARCHAR(50)
        , ErrorNumber INT NULL
        , ErrorMessage NVARCHAR(4000) NULL
    );

    WHILE @loopCount <= @totalCount
    BEGIN
        DECLARE
              @retryCount INT = 0
            , @success BIT = 0
            , @errorNumber INT = NULL
            , @errorMessage NVARCHAR(4000) = NULL;

        SELECT @sqlCommand = generated_maintenance_command
        FROM #tempIndexes
        WHERE Id = @loopCount;

        IF @action = 1
        BEGIN
            WHILE @success = 0 AND @retryCount <= @maxRetries
            BEGIN
                BEGIN TRY
                    SET @message =
                        CASE
                            WHEN @retryCount = 0 THEN N'Starting: '
                            ELSE N'Retrying after deadlock: '
                        END
                        + N'(' + CONVERT(NVARCHAR(20), @loopCount)
                        + N' of ' + CONVERT(NVARCHAR(20), @totalCount)
                        + N') ' + @sqlCommand;

                    RAISERROR(@message, 0, 1) WITH NOWAIT;

                    SET @startTime = SYSDATETIME();
                    
                    SET LOCK_TIMEOUT 5000;
                    EXEC sys.sp_executesql @sqlCommand;
                    SET LOCK_TIMEOUT -1;

                    SET @endTime = SYSDATETIME();
                    SET @diffSec = DATEDIFF(SECOND, @startTime, @endTime);

                    SET @duration = CONCAT(
                          @diffSec / 86400, ':'
                        , RIGHT('00' + CONVERT(VARCHAR(2), (@diffSec % 86400) / 3600), 2), ':'
                        , RIGHT('00' + CONVERT(VARCHAR(2), (@diffSec % 3600) / 60), 2), ':'
                        , RIGHT('00' + CONVERT(VARCHAR(2), @diffSec % 60), 2)
                    );

                    SET @message =
                          N'Completed. StartTime: (' + CONVERT(NVARCHAR(50), @startTime, 121)
                        + N') EndTime: (' + CONVERT(NVARCHAR(50), @endTime, 121)
                        + N') Duration: (' + @duration + N')';

                    RAISERROR(@message, 0, 1) WITH NOWAIT;
                    SET @message = REPLICATE(N'-', 110);
                    RAISERROR(@message, 0, 1) WITH NOWAIT;

                    INSERT INTO #ProcessedIndexes
                    (
                          Id
                        , DatabaseName
                        , SqlStatement
                        , StartTime
                        , EndTime
                        , Duration
                        , Status
                        , ErrorNumber
                        , ErrorMessage
                    )
                    VALUES
                    (
                          @loopCount
                        , DB_NAME()
                        , @sqlCommand
                        , @startTime
                        , @endTime
                        , @duration
                        , CASE WHEN @retryCount = 0 THEN 'SUCCESS' ELSE 'SUCCESS_AFTER_RETRY' END
                        , NULL
                        , NULL
                    );

                    SET @success = 1;
                END TRY
                BEGIN CATCH
                    SET LOCK_TIMEOUT -1;
                    SET @endTime = SYSDATETIME();
                    SET @errorNumber = ERROR_NUMBER();
                    SET @errorMessage = ERROR_MESSAGE();

                    IF @startTime IS NULL
                        SET @startTime = @endTime;

                    SET @diffSec = DATEDIFF(SECOND, @startTime, @endTime);

                    SET @duration = CONCAT(
                          @diffSec / 86400, ':'
                        , RIGHT('00' + CONVERT(VARCHAR(2), (@diffSec % 86400) / 3600), 2), ':'
                        , RIGHT('00' + CONVERT(VARCHAR(2), (@diffSec % 3600) / 60), 2), ':'
                        , RIGHT('00' + CONVERT(VARCHAR(2), @diffSec % 60), 2)
                    );

                    IF @errorNumber = 1205 AND @retryCount < @maxRetries
                    BEGIN
                        SET @message =
                              N'Deadlock encountered on item '
                            + CONVERT(NVARCHAR(20), @loopCount)
                            + N'. Waiting before retry.';

                        RAISERROR(@message, 0, 1) WITH NOWAIT;
                        SET @retryCount += 1;
                        WAITFOR DELAY @retryDelay;
                    END
                    ELSE IF @errorNumber = 1222
                    BEGIN
                        SET @message =
                              N'Skipping item ' + CONVERT(NVARCHAR(20), @loopCount)
                            + N' due to lock timeout.';

                        RAISERROR(@message, 0, 1) WITH NOWAIT;
                        SET @message = REPLICATE(N'-', 110);
                        RAISERROR(@message, 0, 1) WITH NOWAIT;

                        INSERT INTO #ProcessedIndexes
                        VALUES
                        (
                              @loopCount
                            , DB_NAME()
                            , @sqlCommand
                            , @startTime
                            , @endTime
                            , @duration
                            , 'SKIPPED_LOCK_TIMEOUT'
                            , @errorNumber
                            , @errorMessage
                        );

                        SET @success = 1;
                    END
                    ELSE
                    BEGIN
                        SET @message =
                              N'Failed item ' + CONVERT(NVARCHAR(20), @loopCount)
                            + N'. ErrorNumber: ' + CONVERT(NVARCHAR(20), @errorNumber)
                            + N'. ErrorMessage: ' + @errorMessage;

                        RAISERROR(@message, 0, 1) WITH NOWAIT;
                        SET @message = REPLICATE(N'-', 110);
                        RAISERROR(@message, 0, 1) WITH NOWAIT;

                        INSERT INTO #ProcessedIndexes
                        (
                              Id
                            , DatabaseName
                            , SqlStatement
                            , StartTime
                            , EndTime
                            , Duration
                            , Status
                            , ErrorNumber
                            , ErrorMessage
                        )
                        VALUES
                        (
                              @loopCount
                            , DB_NAME()
                            , @sqlCommand
                            , @startTime
                            , @endTime
                            , @duration
                            , CASE
                                  WHEN @errorNumber = 1205 THEN 'SKIPPED_AFTER_DEADLOCK_RETRY'
                                  ELSE 'FAILED'
                              END
                            , @errorNumber
                            , @errorMessage
                        );

                        SET @success = 1;
                    END
                END CATCH
            END
        END
        ELSE
            BEGIN
                IF (@action = 1)
                    BEGIN
                        RAISERROR(@sqlCommand, 0, 1) WITH NOWAIT;
                    END
            END

        SET @loopCount += 1;
    END

    IF @action = 0
        BEGIN
            SELECT *
            FROM #tempIndexes
            ORDER BY Id;
        END
    ELSE 
    IF @showResults = 1
        BEGIN
            SELECT *
            FROM #ProcessedIndexes
            ORDER BY Id;
        END
END;
