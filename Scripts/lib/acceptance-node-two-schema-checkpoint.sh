#!/bin/sh

# Release-only, privacy-safe schema evidence. Each stage accepts only one
# fixed output and never copies PostgreSQL stderr or SQL data into the log.
node_two_schema_checkpoint() {
  schema_checkpoint_phase=${1:-}
  case "$schema_checkpoint_phase" in
    initial-ready|after-restarts|before-privacy-audit) ;;
    *) return 1 ;;
  esac
  schema_checkpoint_release=${transport_release_images:-${NODE_TWO_SCHEMA_CHECKPOINT_RELEASE:-0}}
  [ "$schema_checkpoint_release" = 1 ] || return 0
  schema_checkpoint_container=${release_replacement_container:-${NODE_TWO_SCHEMA_CHECKPOINT_CONTAINER:-}}
  schema_checkpoint_role=${node_database_inspection_role:-plainpost_sync_node}
  # The replacement database is immutable for this diagnostic. In release
  # mode node_one_database_name may point at a rotated restore database.
  schema_checkpoint_database=plainpost_sync_node
  schema_checkpoint_log=${runtime_log:-${NODE_TWO_SCHEMA_CHECKPOINT_RUNTIME_LOG:-/dev/null}}
  schema_checkpoint_emit_failure() {
    printf 'node-two-schema-checkpoint phase=%s status=failed cause=%s\n' "$schema_checkpoint_phase" "$1" >>"$schema_checkpoint_log"
    return 1
  }
  if [ -z "$schema_checkpoint_container" ]; then
    schema_checkpoint_emit_failure container-missing
    return 1
  fi
  schema_checkpoint_container_state=$(docker inspect --format '{{.State.Status}}' "$schema_checkpoint_container" 2>/dev/null) || schema_checkpoint_container_state=''
  case "$schema_checkpoint_container_state" in
    running) ;;
    '') schema_checkpoint_emit_failure container-missing; return 1 ;;
    *) schema_checkpoint_emit_failure container-not-running; return 1 ;;
  esac
  if ! schema_checkpoint_result=$(docker exec "$schema_checkpoint_container" psql -X -q -At \
    -U "$schema_checkpoint_role" -d "$schema_checkpoint_database" -c 'SELECT 1' 2>/dev/null); then
    schema_checkpoint_emit_failure psql-connect
    return 1
  fi
  [ "$schema_checkpoint_result" = 1 ] || { schema_checkpoint_emit_failure unexpected-output; return 1; }
  if [ "$schema_checkpoint_phase" = before-privacy-audit ]; then
    schema_checkpoint_reset_query=$(cat <<'SQL'
SELECT CASE
  WHEN current_schema() IS DISTINCT FROM 'public' THEN 'reset-mismatch'
  WHEN to_regnamespace('public') IS NULL THEN 'reset-mismatch'
  WHEN to_regclass('public.node_schema_migrations') IS NOT NULL THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f','S','c')) THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname <> 'public' AND nspname <> 'information_schema' AND nspname NOT LIKE 'pg_%') THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public') THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typtype IN ('b','c','d','e','r','m')) THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname <> 'plpgsql') THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_largeobject_metadata) THEN 'reset-mismatch'
  WHEN (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()) <> 'plainpost_restore_admin' THEN 'reset-mismatch'
  WHEN (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public') <> 'plainpost_restore_admin' THEN 'reset-mismatch'
  WHEN NOT has_schema_privilege('plainpost_sync_node','public','USAGE,CREATE') THEN 'reset-mismatch'
  WHEN has_schema_privilege(0,'public','USAGE') THEN 'reset-mismatch'
  WHEN has_schema_privilege('plainpost_restore_stage','public','USAGE,CREATE') THEN 'reset-mismatch'
  WHEN NOT has_database_privilege('plainpost_sync_node',current_database(),'CONNECT') THEN 'reset-mismatch'
  WHEN NOT has_database_privilege('plainpost_restore_admin',current_database(),'CONNECT') THEN 'reset-mismatch'
  WHEN has_database_privilege('plainpost_restore_stage',current_database(),'CONNECT') THEN 'reset-mismatch'
  WHEN has_database_privilege(0,current_database(),'CONNECT') THEN 'reset-mismatch'
  WHEN EXISTS (SELECT 1 FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) x WHERE d.defaclnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public') AND x.grantee=0) THEN 'reset-mismatch'
  WHEN (SELECT count(*) FROM (
    WITH expected(grantee,grantor,privilege_type,is_grantable) AS (
      SELECT d.datdba,d.datdba,privilege_type,false FROM pg_database d CROSS JOIN (VALUES ('CONNECT'),('CREATE'),('TEMPORARY')) privileges(privilege_type) WHERE d.datname=current_database()
      UNION ALL SELECT r.oid,d.datdba,'CONNECT',false FROM pg_database d JOIN pg_roles r ON r.rolname='plainpost_sync_node' WHERE d.datname=current_database()
    ), actual AS (
      SELECT x.grantee,x.grantor,x.privilege_type,x.is_grantable FROM pg_database d CROSS JOIN LATERAL aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) x WHERE d.datname=current_database()
    ) SELECT * FROM expected EXCEPT SELECT * FROM actual UNION ALL SELECT * FROM actual EXCEPT SELECT * FROM expected
  ) differences) <> 0 THEN 'reset-mismatch'
  WHEN (SELECT count(*) FROM (
    WITH expected(grantee,grantor,privilege_type,is_grantable) AS (
      SELECT grantee.oid,owner.oid,privilege_type,false FROM pg_roles grantee CROSS JOIN pg_roles owner CROSS JOIN (VALUES ('USAGE'),('CREATE')) privileges(privilege_type) WHERE grantee.rolname='plainpost_restore_admin' AND owner.rolname='plainpost_restore_admin'
      UNION ALL SELECT grantee.oid,owner.oid,privilege_type,false FROM pg_roles grantee CROSS JOIN pg_roles owner CROSS JOIN (VALUES ('USAGE'),('CREATE')) privileges(privilege_type) WHERE grantee.rolname='plainpost_sync_node' AND owner.rolname='plainpost_restore_admin'
    ), actual AS (
      SELECT x.grantee,x.grantor,x.privilege_type,x.is_grantable FROM pg_namespace n CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl,acldefault('n',n.nspowner))) x WHERE n.nspname='public'
    ) SELECT * FROM expected EXCEPT SELECT * FROM actual UNION ALL SELECT * FROM actual EXCEPT SELECT * FROM expected
  ) differences) <> 0 THEN 'reset-mismatch'
  WHEN (SELECT count(*) FROM (
    WITH specs(owner_name,object_type,schema_name,grantee_name,privileges) AS (
      VALUES ('plainpost_restore_admin','r','','plainpost_sync_node',ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']::text[]),('plainpost_restore_admin','S','','plainpost_sync_node',ARRAY['USAGE','SELECT','UPDATE']::text[]),('plainpost_restore_admin','f','','plainpost_sync_node',ARRAY['EXECUTE']::text[]),('plainpost_restore_admin','r','','plainpost_restore_admin',ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']::text[]),('plainpost_restore_admin','S','','plainpost_restore_admin',ARRAY['USAGE','SELECT','UPDATE']::text[]),('plainpost_restore_admin','f','','plainpost_restore_admin',ARRAY['EXECUTE']::text[]),('plainpost_sync_node','f','','plainpost_sync_node',ARRAY['EXECUTE']::text[])
    ), expected AS (
      SELECT owner_name,object_type,schema_name,grantee_name,owner_name AS grantor_name,privilege_type,false AS is_grantable FROM specs CROSS JOIN LATERAL unnest(specs.privileges) privileges(privilege_type)
    ), actual AS (
      SELECT owner.rolname::text,d.defaclobjtype::text,COALESCE(n.nspname,''::text),COALESCE(grantee.rolname,'PUBLIC'::name)::text,grantor.rolname::text,x.privilege_type::text,x.is_grantable FROM pg_default_acl d JOIN pg_roles owner ON owner.oid=d.defaclrole LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) x LEFT JOIN pg_roles grantee ON grantee.oid=x.grantee LEFT JOIN pg_roles grantor ON grantor.oid=x.grantor WHERE owner.rolname IN ('plainpost_restore_admin','plainpost_sync_node','plainpost_restore_stage') AND (d.defaclnamespace=0 OR n.nspname='public')
    ) SELECT * FROM expected EXCEPT SELECT * FROM actual UNION ALL SELECT * FROM actual EXCEPT SELECT * FROM expected
  ) differences) <> 0 THEN 'reset-mismatch'
  ELSE 'reset-passed'
END
SQL
)
    if ! schema_checkpoint_result=$(docker exec "$schema_checkpoint_container" psql -X -q -At \
      -U "$schema_checkpoint_role" -d "$schema_checkpoint_database" \
      -c "$schema_checkpoint_reset_query" 2>/dev/null); then
      schema_checkpoint_emit_failure reset-query
      return 1
    fi
    case "$schema_checkpoint_result" in
      reset-passed)
        if ! docker exec "$schema_checkpoint_container" psql -X -q -At -v ON_ERROR_STOP=1 \
          -U "$schema_checkpoint_role" -d "$schema_checkpoint_database" \
          -c 'BEGIN; CREATE TABLE public.__plainpost_reset_probe (id integer); DROP TABLE public.__plainpost_reset_probe; COMMIT' >/dev/null 2>&1; then
          schema_checkpoint_emit_failure reset-probe
          return 1
        fi
        printf 'node-two-schema-checkpoint phase=%s status=passed state=reset\n' "$schema_checkpoint_phase" >>"$schema_checkpoint_log"
        return 0
        ;;
      reset-mismatch) schema_checkpoint_emit_failure reset-mismatch; return 1 ;;
      *) schema_checkpoint_emit_failure unexpected-output; return 1 ;;
    esac
  fi
  if ! schema_checkpoint_result=$(docker exec "$schema_checkpoint_container" psql -X -q -At \
    -U "$schema_checkpoint_role" -d "$schema_checkpoint_database" \
    -c "SELECT CASE WHEN to_regclass('public.node_schema_migrations') IS NULL THEN 'ledger-missing' WHEN COALESCE((SELECT version::text || ':' || name FROM node_schema_migrations ORDER BY version DESC LIMIT 1), '') <> '27:0027_capture_optional_address_search_path.sql' THEN 'head-mismatch' ELSE 'head-passed' END" 2>/dev/null); then
    schema_checkpoint_emit_failure migration-ledger
    return 1
  fi
  case "$schema_checkpoint_result" in
    ledger-missing) schema_checkpoint_emit_failure migration-ledger; return 1 ;;
    head-mismatch) schema_checkpoint_emit_failure migration-head; return 1 ;;
    head-passed) ;;
    *) schema_checkpoint_emit_failure unexpected-output; return 1 ;;
  esac
  for schema_checkpoint_relation in node_installation_state node_current_authority_state node_secrets; do
    if ! schema_checkpoint_result=$(docker exec "$schema_checkpoint_container" psql -X -q -At \
      -U "$schema_checkpoint_role" -d "$schema_checkpoint_database" \
      -c "SELECT CASE WHEN to_regclass('public.$schema_checkpoint_relation') IS NULL THEN 'missing' ELSE 'present' END" 2>/dev/null); then
      schema_checkpoint_emit_failure relation-query
      return 1
    fi
    case "$schema_checkpoint_result" in
      present) ;;
      missing)
        case "$schema_checkpoint_relation" in
          node_installation_state) schema_checkpoint_cause=node-installation-state ;;
          node_current_authority_state) schema_checkpoint_cause=node-current-authority-state ;;
          node_secrets) schema_checkpoint_cause=node-secrets ;;
        esac
        schema_checkpoint_emit_failure "$schema_checkpoint_cause"
        return 1
        ;;
      *) schema_checkpoint_emit_failure unexpected-output; return 1 ;;
    esac
  done
  printf 'node-two-schema-checkpoint phase=%s status=passed\n' "$schema_checkpoint_phase" >>"$schema_checkpoint_log"
}

if [ "${NODE_TWO_SCHEMA_CHECKPOINT:-}" = 1 ]; then
  node_two_schema_checkpoint "${1:-}"
fi
