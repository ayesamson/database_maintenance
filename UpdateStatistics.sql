/*
    Statistics Maintenance Script
    Copyright (c) 2026 ayesamson
    https://github.com/ayesamson

    Licensed under the MIT License.
    See the LICENSE file in the project root for license information.
*/
SET NOCOUNT ON;
BEGIN
    DROP TABLE IF EXISTS #tempStats;
    DECLARE 
        @action BIT = 0,
        @startTime DATETIME,
        @endTime DATETIME,
        @duration VARCHAR(50),
        @message VARCHAR(500),
        @loopCount INT = 1,
        @totalCount INT = 0,
        @sqlCommand VARCHAR(1000),
        @tableName SYSNAME = NULL, -- NULL for all tables or for a specific table: 'Schema.TableName',
        @showResults BIT = 1;

    DECLARE 
          @min_row_count_for_consideration bigint = 10000
        , @urgent_modification_count bigint = 100000
        , @high_modification_count bigint = 25000
        , @urgent_change_pct decimal(9,4) = 0.20   -- 20%
        , @high_change_pct   decimal(9,4) = 0.10   -- 10%
        , @medium_change_pct decimal(9,4) = 0.05   -- 5%
        , @fullscan_row_limit bigint = 1000000
        , @small_table_fullscan_limit bigint = 500000
        , @sample_very_large_pct int = 10
        , @sample_large_pct int = 20
        , @sample_medium_pct int = 50
        , @top_n int = 200;

    ;WITH table_rows AS
    (
        SELECT
              p.object_id,
              SUM(CASE WHEN p.index_id IN (0,1) THEN p.rows ELSE 0 END) AS table_row_count
        FROM sys.partitions AS p
        WHERE NOT EXISTS (
            SELECT 1
            FROM sys.dm_tran_locks AS tl
            WHERE tl.resource_database_id = DB_ID()
              AND tl.resource_type = 'OBJECT'
              AND tl.request_mode = 'Sch-M'
              AND tl.request_status = 'GRANT'
              AND tl.resource_associated_entity_id = p.object_id
        )
        GROUP BY p.object_id
    ),
    stats_base AS
    (
        SELECT
              s.object_id
            , s.stats_id
            , sch.name AS schema_name
            , o.name AS table_name
            , s.name AS stats_name
            , s.auto_created
            , s.user_created
            , s.no_recompute
            , s.has_filter
            , s.filter_definition
            , sp.last_updated
            , sp.rows AS stats_rows
            , sp.rows_sampled
            , sp.steps
            , sp.unfiltered_rows
            , sp.modification_counter
            , sp.persisted_sample_percent
            , tr.table_row_count
            , CASE 
                WHEN tr.table_row_count > 0 
                    THEN CONVERT(decimal(19,6), sp.modification_counter * 1.0 / tr.table_row_count)
                ELSE 0 
              END AS modification_pct_of_table
            , CASE 
                WHEN sp.rows > 0 
                    THEN CONVERT(decimal(19,6), sp.rows_sampled * 1.0 / sp.rows)
                ELSE NULL
              END AS prior_sample_ratio
            , DATEDIFF(day, sp.last_updated, SYSUTCDATETIME()) AS days_since_update
        FROM sys.stats AS s
        INNER JOIN sys.objects AS o
            ON o.object_id = s.object_id
        INNER JOIN sys.schemas AS sch
            ON sch.schema_id = o.schema_id
        INNER JOIN table_rows AS tr
            ON tr.object_id = s.object_id
        OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
        WHERE 
               o.type = 'U'
           AND o.is_ms_shipped = 0
           AND OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
            AND (
                   @TableName IS NULL
                OR o.name = @TableName
                OR CONCAT(sch.name, '.', o.name) = @TableName
            )
           AND NOT EXISTS
               (
                 SELECT 1
                 FROM sys.indexes i
                 WHERE i.object_id = s.object_id
                   AND i.is_hypothetical = 1
                   AND i.index_id = s.stats_id
               )
    ),
    scored AS
    (
        SELECT
              *
            , CASE 
                WHEN table_row_count < @min_row_count_for_consideration 
                     AND modification_counter < 1000
                    THEN 'IGNORE_SMALL_LOW_CHANGE'
                WHEN modification_counter >= @urgent_modification_count
                    THEN 'URGENT'
                WHEN modification_counter >= @high_modification_count
                     OR modification_pct_of_table >= @urgent_change_pct
                    THEN 'HIGH'
                WHEN modification_pct_of_table >= @high_change_pct
                    THEN 'MEDIUM'
                WHEN modification_pct_of_table >= @medium_change_pct
                    THEN 'LOW'
                ELSE 'WATCH'
              END AS action_bucket
            , (
                  (CASE 
                       WHEN modification_counter >= 1000000 THEN 100
                       WHEN modification_counter >= 250000  THEN 85
                       WHEN modification_counter >= 100000  THEN 70
                       WHEN modification_counter >= 25000   THEN 50
                       WHEN modification_counter >= 5000    THEN 30
                       ELSE 0
                   END)
                + (CASE 
                       WHEN modification_pct_of_table >= 0.50 THEN 50
                       WHEN modification_pct_of_table >= 0.20 THEN 35
                       WHEN modification_pct_of_table >= 0.10 THEN 25
                       WHEN modification_pct_of_table >= 0.05 THEN 15
                       ELSE 0
                   END)
                + (CASE
                       WHEN prior_sample_ratio IS NULL THEN 5
                       WHEN prior_sample_ratio < 0.10 THEN 15
                       WHEN prior_sample_ratio < 0.25 THEN 10
                       WHEN prior_sample_ratio < 0.50 THEN 5
                       ELSE 0
                   END)
                + (CASE
                       WHEN has_filter = 1 THEN 5
                       ELSE 0
                   END)
              ) AS urgency_score
        FROM stats_base
        WHERE 
            table_row_count IS NOT NULL
            AND modification_counter IS NOT NULL
    ),
    candidates AS
    (
        SELECT
              s.*
            , CASE
                WHEN s.table_row_count <= @small_table_fullscan_limit
                    THEN 'TABLE'
                ELSE 'STAT'
              END AS command_level
            , CASE
                WHEN s.table_row_count <= @small_table_fullscan_limit
                    THEN 'FULLSCAN'
                WHEN s.action_bucket IN ('URGENT','HIGH') AND s.table_row_count <= @fullscan_row_limit
                    THEN 'FULLSCAN'
                WHEN s.table_row_count >= 100000000
                    THEN CONCAT('SAMPLE ', @sample_very_large_pct, ' PERCENT')
                WHEN s.table_row_count >= 10000000
                    THEN CONCAT('SAMPLE ', @sample_large_pct, ' PERCENT')
                WHEN s.table_row_count >= @fullscan_row_limit
                    THEN CONCAT('SAMPLE ', @sample_medium_pct, ' PERCENT')
                ELSE 'FULLSCAN'
              END AS recommended_sampling
            , CASE
                WHEN s.table_row_count <= @small_table_fullscan_limit
                     AND s.action_bucket IN ('URGENT','HIGH','MEDIUM','LOW')
                    THEN
                        'UPDATE STATISTICS '
                        + QUOTENAME(s.schema_name) + '.' + QUOTENAME(s.table_name)
                        + ' WITH FULLSCAN;'
                WHEN s.action_bucket IN ('URGENT','HIGH','MEDIUM','LOW')
                    THEN
                        'UPDATE STATISTICS '
                        + QUOTENAME(s.schema_name) + '.' + QUOTENAME(s.table_name)
                        + ' ' + QUOTENAME(s.stats_name)
                        + ' WITH '
                        + CASE
                            WHEN s.action_bucket IN ('URGENT','HIGH') AND s.table_row_count <= @fullscan_row_limit
                                THEN 'FULLSCAN'
                            WHEN s.table_row_count >= 100000000
                                THEN CONCAT('SAMPLE ', @sample_very_large_pct, ' PERCENT')
                            WHEN s.table_row_count >= 10000000
                                THEN CONCAT('SAMPLE ', @sample_large_pct, ' PERCENT')
                            WHEN s.table_row_count >= @fullscan_row_limit
                                THEN CONCAT('SAMPLE ', @sample_medium_pct, ' PERCENT')
                            ELSE 'FULLSCAN'
                          END
                        + CASE
                            WHEN s.table_row_count < 1000000 THEN ', MAXDOP = 1'
                            WHEN s.table_row_count < 10000000 THEN ', MAXDOP = 2'
                            WHEN s.table_row_count < 100000000 THEN ', MAXDOP = 4'
                            ELSE ''
                          END + ';'
                ELSE NULL
              END AS generated_update_command
        FROM scored AS s
        WHERE s.action_bucket IN ('URGENT','HIGH','MEDIUM','LOW')
    ),
    deduped AS
    (
        SELECT
              c.*
            , CASE
                WHEN c.command_level = 'TABLE'
                    THEN ROW_NUMBER() OVER
                         (
                             PARTITION BY c.schema_name, c.table_name
                             ORDER BY
                                   c.urgency_score DESC
                                 , c.modification_counter DESC
                                 , c.modification_pct_of_table DESC
                                 , c.days_since_update DESC
                                 , c.stats_name ASC
                         )
                ELSE 1
              END AS table_dedupe_rn
        FROM candidates AS c
        WHERE c.generated_update_command IS NOT NULL
    ),
    ranked AS
    (
        SELECT TOP (@top_n)
              *
        FROM deduped
        WHERE table_dedupe_rn = 1
        ORDER BY
              urgency_score DESC
            , modification_counter DESC
            , modification_pct_of_table DESC
            , table_row_count DESC
            , days_since_update DESC
    ),
    results AS
    (
        SELECT
              ROW_NUMBER() OVER
              (
                  ORDER BY
                       urgency_score DESC,
                       modification_counter DESC,
                       modification_pct_of_table DESC,
                       table_row_count DESC,
                       days_since_update DESC
              ) AS row_num
            , '' AS [Statistics]
            , [schema_name]
            , table_name
            , stats_name
            , auto_created
            , user_created
            , no_recompute
            , has_filter
            , table_row_count
            , stats_rows
            , rows_sampled
            , CAST(prior_sample_ratio * 100.0 AS decimal(9,2)) AS prior_sample_pct
            , modification_counter
            , CAST(modification_pct_of_table * 100.0 AS decimal(9,2)) AS modification_pct_of_table
            , last_updated
            , days_since_update
            , action_bucket
            , urgency_score
            , command_level
            , recommended_sampling
            , generated_update_command
        FROM ranked
    )
    SELECT 
        ROW_NUMBER() OVER (ORDER BY row_num) AS Id,
        *
    INTO #tempStats
    FROM results
    ORDER BY row_num;
    SET @totalCount = @@ROWCOUNT;

    DROP TABLE IF EXISTS #ProcessedStats;

    CREATE TABLE #ProcessedStats (
        Id INT,
        DatabaseName VARCHAR(128),
        SqlStatement VARCHAR(1000),
        StartTime DATETIME,
        EndTime DATETIME,
        Duration VARCHAR(50),
        Status VARCHAR(50),
        ErrorNumber INT NULL,
        ErrorMessage VARCHAR(4000) NULL
    );

    WHILE (@loopCount <= @totalCount)
    BEGIN
        DECLARE 
              @retryCount INT = 0
            , @maxRetries INT = 1
            , @success BIT = 0
            , @errorNumber INT = NULL
            , @errorMessage VARCHAR(4000) = NULL
            , @diff_sec BIGINT;

        SELECT @sqlCommand = generated_update_command 
        FROM #tempStats 
        WHERE Id = @loopCount;

        IF (@action = 1)
        BEGIN
            WHILE (@success = 0 AND @retryCount <= @maxRetries)
            BEGIN
                BEGIN TRY
                    SET @message = 
                        CASE 
                            WHEN @retryCount = 0 THEN 'Starting: '
                            ELSE 'Retrying after deadlock: '
                        END
                        + '(' + TRY_CAST(@loopCount AS VARCHAR(20)) 
                        + ' of ' + TRY_CAST(@totalCount AS VARCHAR(20)) 
                        + ') ' + @sqlCommand;

                    RAISERROR(@message, 0, 1) WITH NOWAIT;

                    SET @startTime = GETDATE();

                    SET LOCK_TIMEOUT 5000;
                    EXEC(@sqlCommand);
                    SET LOCK_TIMEOUT -1;

                    SET @endTime = GETDATE();

                    SET @diff_sec = DATEDIFF(SECOND, @startTime, @endTime);

                    SET @duration = CONCAT(
                        @diff_sec / 86400, ':',
                        RIGHT('00' + CAST((@diff_sec % 86400) / 3600 AS VARCHAR(2)), 2), ':',
                        RIGHT('00' + CAST((@diff_sec % 3600) / 60 AS VARCHAR(2)), 2), ':',
                        RIGHT('00' + CAST(@diff_sec % 60 AS VARCHAR(2)), 2)
                    );

                    SET @message = 
                        'Completed. StartTime: (' + TRY_CONVERT(VARCHAR(50), @startTime, 121) 
                        + ') EndTime: (' + TRY_CONVERT(VARCHAR(50), @endTime, 121) 
                        + ') Duration: (' + @duration + ')';

                    RAISERROR(@message, 0, 1) WITH NOWAIT;
                    SET @message = REPLICATE('-', 110);
                    RAISERROR(@message, 0, 1) WITH NOWAIT;

                    INSERT INTO #ProcessedStats 
                    (
                        Id, DatabaseName, SqlStatement, StartTime, EndTime, Duration, 
                        [Status], ErrorNumber, ErrorMessage
                    ) 
                    VALUES 
                    (
                        @loopCount, DB_NAME(), @sqlCommand, @startTime, @endTime, @duration,
                        CASE WHEN @retryCount = 0 THEN 'SUCCESS' ELSE 'SUCCESS_AFTER_RETRY' END,
                        NULL, NULL
                    );

                    SET @success = 1;
                END TRY
                BEGIN CATCH
                    SET LOCK_TIMEOUT -1;
                    SET @endTime = GETDATE();
                    SET @errorNumber = ERROR_NUMBER();
                    SET @errorMessage = ERROR_MESSAGE();

                    SET @diff_sec = DATEDIFF(SECOND, @startTime, @endTime);

                    SET @duration = CONCAT(
                        @diff_sec / 86400, ':',
                        RIGHT('00' + CAST((@diff_sec % 86400) / 3600 AS VARCHAR(2)), 2), ':',
                        RIGHT('00' + CAST((@diff_sec % 3600) / 60 AS VARCHAR(2)), 2), ':',
                        RIGHT('00' + CAST(@diff_sec % 60 AS VARCHAR(2)), 2)
                    );

                    IF (@errorNumber = 1205 AND @retryCount < @maxRetries)
                        BEGIN
                            SET @message = 
                                'Deadlock encountered on item ' 
                                + TRY_CAST(@loopCount AS VARCHAR(20)) 
                                + '. Waiting 10 seconds before retry.';

                            RAISERROR(@message, 0, 1) WITH NOWAIT;

                            SET @retryCount = @retryCount + 1;

                            WAITFOR DELAY '00:00:10';
                        END
                    ELSE IF (@errorNumber = 1222)
                        BEGIN
                            SET @message = 
                                'Skipping item ' + CAST(@loopCount AS VARCHAR(20)) 
                                + ' due to lock timeout (likely ALTER TABLE or schema lock).';

                            RAISERROR(@message, 0, 1) WITH NOWAIT;
                            SET @message = REPLICATE('-', 110);
                            RAISERROR(@message, 0, 1) WITH NOWAIT;

                            INSERT INTO #ProcessedStats 
                            VALUES 
                            (
                                @loopCount, DB_NAME(), @sqlCommand, @startTime, @endTime, @duration,
                                'SKIPPED_LOCK_TIMEOUT',
                                @errorNumber, @errorMessage
                            );

                            SET @success = 1;
                        END
                    ELSE
                        BEGIN
                            SET @message = 
                                'Failed item ' 
                                + TRY_CAST(@loopCount AS VARCHAR(20)) 
                                + '. ErrorNumber: ' + TRY_CAST(@errorNumber AS VARCHAR(20)) 
                                + '. ErrorMessage: ' + @errorMessage;

                            RAISERROR(@message, 0, 1) WITH NOWAIT;
                            SET @message = REPLICATE('-', 110);
                            RAISERROR(@message, 0, 1) WITH NOWAIT;

                            INSERT INTO #ProcessedStats 
                            (
                                Id, DatabaseName, SqlStatement, StartTime, EndTime, Duration, 
                                Status, ErrorNumber, ErrorMessage
                            ) 
                            VALUES 
                            (
                                @loopCount, DB_NAME(), @sqlCommand, @startTime, @endTime, @duration,
                                CASE 
                                    WHEN @errorNumber = 1205 THEN 'SKIPPED_AFTER_DEADLOCK_RETRY'
                                    ELSE 'FAILED'
                                END,
                                @errorNumber, @errorMessage
                            );

                            SET @success = 1;
                        END
                END CATCH
            END
        END
        ELSE
            BEGIN
                RAISERROR(@sqlCommand, 0, 1) WITH NOWAIT;
            END

        SET @loopCount = @loopCount + 1;
    END
            IF (@action = 0)
                BEGIN
                    SELECT * FROM #tempStats;
                END
            ELSE
                BEGIN
                    IF (@showResults = 1)
                        BEGIN
                            SELECT * FROM #ProcessedStats;
                        END
                END
END
