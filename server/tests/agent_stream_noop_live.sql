-- Exercise the production mutation gate with an unchanged normalized snapshot.
CREATE OR REPLACE TEMP TABLE stream_noop_snapshot AS SELECT * FROM agent.stream;
CREATE OR REPLACE TEMP TABLE stream_noop_tombstones AS
SELECT * FROM agent.stream
EXCEPT ALL
SELECT * FROM stream_noop_snapshot;
CREATE OR REPLACE TEMP TABLE stream_noop_upserts AS
SELECT * FROM stream_noop_snapshot
EXCEPT ALL
SELECT * FROM agent.stream;
CREATE OR REPLACE TEMP TABLE stream_noop_ids AS
SELECT id FROM stream_noop_tombstones
UNION ALL
SELECT id FROM stream_noop_upserts;
BEGIN TRANSACTION;
DELETE FROM agent.stream WHERE id IN (SELECT id FROM stream_noop_ids);
INSERT INTO agent.stream BY NAME SELECT * FROM stream_noop_upserts;
COMMIT;
SELECT CASE WHEN count(id) = 0
            THEN 'pass: unchanged snapshot performed zero stream mutations'
            ELSE error('unchanged snapshot would rewrite stream rows') END AS verification
FROM stream_noop_ids;
