-- reads.sql: the read layer over the replica, posted by pull.sql after every pull. CREATE OR REPLACE only, so a
-- re-run is a no-op. Views re-bind at query time, so they survive each pull's table swap.

-- The property graph. duckpgq is not published for DuckDB 1.5.5 (community repo answers 404), so the graph is two
-- views: node (id, label, name, organization_id) and edge (src, dst, label). Soft-deleted rows are not in the graph.
CREATE SCHEMA IF NOT EXISTS graph;
CREATE OR REPLACE VIEW graph.node AS
SELECT id, 'organization' AS label, name, id AS organization_id FROM public.organization
UNION ALL SELECT id, 'project', name, organization_id FROM public.project WHERE deleted_at IS NULL
UNION ALL SELECT id, 'compliance_group', name, organization_id FROM public.compliance_group WHERE deleted_at IS NULL
UNION ALL SELECT id, 'compliance_group_member', NULL, organization_id FROM public.compliance_group_member WHERE deleted_at IS NULL
UNION ALL SELECT id, 'network_company', name, organization_id FROM public.network_company WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW graph.edge AS
SELECT parent_id AS src, id AS dst, 'PARENT_OF' AS label FROM public.organization WHERE parent_id IS NOT NULL
UNION ALL SELECT organization_id, id, 'HAS_PROJECT' FROM public.project WHERE deleted_at IS NULL
UNION ALL SELECT project_id, id, 'HAS_COMPLIANCE_GROUP' FROM public.compliance_group WHERE deleted_at IS NULL AND project_id IS NOT NULL
UNION ALL SELECT compliance_group_id, id, 'HAS_MEMBER' FROM public.compliance_group_member WHERE deleted_at IS NULL
UNION ALL SELECT id, network_company_id, 'IS_COMPANY' FROM public.compliance_group_member WHERE deleted_at IS NULL
UNION ALL SELECT organization_id, id, 'HAS_NETWORK_COMPANY' FROM public.network_company WHERE deleted_at IS NULL;

-- One question, two routes. For an organization: its projects, their compliance groups, member counts, and the
-- requirement-set line counts behind each group. /org/live reads Postgres through the attach at request time;
-- /org/replica reads the copy. Same text, only the catalog differs, so both are rendered from rows and dispatched.
-- A route binds its SQL when created, which is why these are declared here, after the tables exist.
WITH route AS (
    SELECT 'org_live' AS name, '/org/live' AS path, 'pg.public' AS src
    UNION ALL SELECT 'org_replica', '/org/replica', 'public'
), statements AS (
    SELECT name, 'CREATE OR REPLACE ROUTE ' || name || ' POST ' || chr(39) || path || chr(39) || ' AS ' || replace($q$
WITH member AS (
    SELECT compliance_group_id, len(array_agg(id)) AS members
    FROM @SRC.compliance_group_member WHERE organization_id = $org::UUID AND deleted_at IS NULL GROUP BY ALL
), requirement AS (
    SELECT prof.compliance_group_id, prof.name AS requirements_profile,
        len(rs.coverage_requirements::JSON[]) AS coverage_lines, len(rs.general_requirements::JSON[]) AS general_lines
    FROM @SRC.compliance_requirements_profile prof JOIN @SRC.compliance_requirement_set rs ON rs.id = prof.requirement_set_id
    WHERE prof.organization_id = $org::UUID AND prof.deleted_at IS NULL
)
SELECT o.name AS organization, p.name AS project, g.name AS compliance_group, g.direction::VARCHAR AS direction,
    coalesce(m.members, 0) AS members, r.requirements_profile, r.coverage_lines, r.general_lines
FROM @SRC.organization o
JOIN @SRC.project p ON p.organization_id = o.id AND p.deleted_at IS NULL
LEFT JOIN @SRC.compliance_group g ON g.project_id = p.id AND g.deleted_at IS NULL
LEFT JOIN member m ON m.compliance_group_id = g.id
LEFT JOIN requirement r ON r.compliance_group_id = g.id
WHERE o.id = $org::UUID
ORDER BY project, compliance_group, requirements_profile$q$, '@SRC', src) AS statement
    FROM route
), posted AS (
    SELECT array_agg({name: name, statement: statement,
        receipt: quackapi_post('http://127.0.0.1:9511/sql', json_object('sql', statement))}) AS receipts
    FROM statements
)
SELECT r.name, r.receipt.status AS status, r.receipt.body AS body FROM posted CROSS JOIN UNNEST(receipts) AS u(r);
