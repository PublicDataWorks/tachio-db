
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "extensions";

CREATE SCHEMA IF NOT EXISTS "history";

ALTER SCHEMA "history" OWNER TO "postgres";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgsodium" WITH SCHEMA "pgsodium";

COMMENT ON SCHEMA "public" IS 'standard public schema';

CREATE SCHEMA IF NOT EXISTS "tachio";

ALTER SCHEMA "tachio" OWNER TO "postgres";

CREATE EXTENSION IF NOT EXISTS "fuzzystrmatch" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "insert_username" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "moddatetime" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgaudit" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";

CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";

CREATE TYPE "tachio"."linear_action" AS ENUM (
    'remove',
    'update',
    'create',
    'set',
    'highRisk',
    'breached',
    'restore'
);

ALTER TYPE "tachio"."linear_action" OWNER TO "postgres";

CREATE TYPE "tachio"."project_status" AS ENUM (
    'active',
    'paused',
    'completed',
    'archived'
);

ALTER TYPE "tachio"."project_status" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."archive_history_based_on_version_count"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    WITH archived_records AS (
        INSERT INTO history.prompts_history_archive (prompt_id, archived_history)
        SELECT id, history
        FROM prompts
        WHERE jsonb_array_length(history) > 10
        RETURNING prompt_id
    )
    UPDATE prompts
    SET history = jsonb_agg(elements ORDER BY (elements->>'valid_from')::timestamp) -- Keep the latest 10 versions
    FROM (
        SELECT id, jsonb_array_elements(history) AS elements
        FROM prompts
        WHERE jsonb_array_length(history) > 10
    ) AS subquery
    WHERE prompts.id = subquery.id
    AND prompts.id IN (SELECT prompt_id FROM archived_records);
END;
$$;

ALTER FUNCTION "public"."archive_history_based_on_version_count"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fn_record_prompt_history"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Handling updates
    IF TG_OP = 'UPDATE' THEN
        -- Prepend the current version to the history with timestamps
        -- 'valid_to' is NOW(), and 'valid_from' is the last update's 'valid_to'
        NEW.history := jsonb_insert(NEW.history, '{0}', jsonb_build_object(
            'version', OLD,
            'timestamp', NOW() -- Current timestamp marks the end of the validity for the previous version
        ));
    ELSIF TG_OP = 'INSERT' THEN
        -- For inserts, initialize the history with the version being inserted
        -- No 'valid_from' or 'valid_to', just a 'timestamp' marking when it was created
        NEW.history := jsonb_build_array(jsonb_build_object(
            'version', NEW,
            'timestamp', NOW() -- Timestamp of when this version (initial) was created
        ));
    END IF;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."fn_record_prompt_history"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."match_memories"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) RETURNS TABLE("id" bigint, "key" "text", "value" "text", "user_id" "text", "related_message_id" bigint, "similarity" double precision)
    LANGUAGE "sql" STABLE
    AS $$
select
  memories.id,
  memories.key,
  memories.value,
  memories.user_id,
  memories.related_message_id,
  1 - (memories.embedding <=> query_embedding) as similarity
from memories
where 1 - (memories.embedding <=> query_embedding) > match_threshold
order by similarity desc
limit match_count;
$$;

ALTER FUNCTION "public"."match_memories"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_modified_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
   NEW.updated_at = now(); 
   RETURN NEW; 
END;
$$;

ALTER FUNCTION "public"."update_modified_column"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "tachio"."store_history"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
    old_data JSONB;
BEGIN
    old_data = to_jsonb(OLD) - 'history' - 'created_at';

    IF NEW.history IS NULL THEN
        NEW.history := '[]';
    END IF;
    NEW.history = jsonb_insert(NEW.history, '{-1}', old_data);

    RETURN NEW;
END;$$;

ALTER FUNCTION "tachio"."store_history"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

CREATE TABLE IF NOT EXISTS "history"."prompts_history_archive" (
    "id" integer NOT NULL,
    "prompt_id" integer,
    "archived_history" "jsonb",
    "archived_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE "history"."prompts_history_archive" OWNER TO "postgres";

CREATE SEQUENCE IF NOT EXISTS "history"."prompts_history_archive_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER TABLE "history"."prompts_history_archive_id_seq" OWNER TO "postgres";

ALTER SEQUENCE "history"."prompts_history_archive_id_seq" OWNED BY "history"."prompts_history_archive"."id";

CREATE TABLE IF NOT EXISTS "public"."config" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "config_key" "text" NOT NULL,
    "config_value" "text" NOT NULL,
    "history" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL
);

ALTER TABLE "public"."config" OWNER TO "postgres";

ALTER TABLE "public"."config" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."config_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."memories" (
    "id" bigint NOT NULL,
    "embedding" "public"."vector"(1536),
    "embedding2" "public"."vector"(1024),
    "embedding3" "public"."vector"(1536),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "key" "text",
    "value" "text",
    "user_id" "text",
    "resource_id" "text",
    "memory_type" "text",
    "related_message_id" bigint,
    "conversation_id" "text"
);

ALTER TABLE "public"."memories" OWNER TO "postgres";

ALTER TABLE "public"."memories" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."memories_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" bigint NOT NULL,
    "embedding" "public"."vector"(1536),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "key" "text",
    "value" "text",
    "user_id" "text",
    "channel_id" "text",
    "guild_id" "text",
    "conversation_id" "text",
    "response_id" bigint
);

ALTER TABLE "public"."messages" OWNER TO "postgres";

ALTER TABLE "public"."messages" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."messages_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."prompts" (
    "id" integer NOT NULL,
    "prompt_name" "text",
    "prompt_text" "text",
    "notes" "text",
    "type" "text",
    "active" boolean,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived" boolean DEFAULT false,
    "history" "jsonb" DEFAULT '[]'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."prompts" OWNER TO "postgres";

ALTER TABLE "public"."prompts" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."prompts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."todos" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text",
    "description" "text"
);

ALTER TABLE "public"."todos" OWNER TO "postgres";

ALTER TABLE "public"."todos" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."todos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."emails" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "email_address" "text" NOT NULL
);

ALTER TABLE "tachio"."emails" OWNER TO "postgres";

ALTER TABLE "tachio"."emails" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."emails_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."github_webhooks" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" NOT NULL,
    "action" "text",
    "target_type" "text" NOT NULL,
    "repository_url" "text" NOT NULL,
    "title" "text",
    "body" "text",
    "issue_id" bigint,
    "sender_id" bigint NOT NULL,
    "repository_created_at" timestamp with time zone,
    "repository_updated_at" timestamp with time zone
);

ALTER TABLE "tachio"."github_webhooks" OWNER TO "postgres";

ALTER TABLE "tachio"."github_webhooks" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."github_webhooks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."linear_projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "team_id" "uuid"
);

ALTER TABLE "tachio"."linear_projects" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "tachio"."linear_teams" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);

ALTER TABLE "tachio"."linear_teams" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "tachio"."linear_webhooks" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" NOT NULL,
    "data" "jsonb",
    "url" "text",
    "updated_from" "jsonb",
    "webhook_timestamp" timestamp with time zone NOT NULL,
    "action" "tachio"."linear_action" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "actor" "jsonb",
    "id" bigint NOT NULL,
    "webhook_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "team_id" "uuid"
);

ALTER TABLE "tachio"."linear_webhooks" OWNER TO "postgres";

COMMENT ON COLUMN "tachio"."linear_webhooks"."project_id" IS 'Equivalent to a subproject or todo in Tachio’s db';

COMMENT ON COLUMN "tachio"."linear_webhooks"."team_id" IS 'Connected to a project in Tachio’s db. TODO: Should be a foreign key to projects table';

ALTER TABLE "tachio"."linear_webhooks" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."linear_webhooks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."org_emails" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "org_id" bigint NOT NULL,
    "email_id" bigint NOT NULL
);

ALTER TABLE "tachio"."org_emails" OWNER TO "postgres";

COMMENT ON TABLE "tachio"."org_emails" IS 'Map org to its second email addresses';

CREATE TABLE IF NOT EXISTS "tachio"."org_slack_channels" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "org_id" bigint NOT NULL,
    "slack_channel_id" bigint NOT NULL
);

ALTER TABLE "tachio"."org_slack_channels" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "tachio"."orgs" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "shortname" "text" NOT NULL,
    "aliases" "text"[],
    "first_contact" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "website" "text",
    "primary_email_address" "text",
    "primary_slack_channel_id" bigint,
    "summary" "text",
    "note" "text",
    "missive_conversation_id" "uuid" NOT NULL,
    "missive_label_id" "uuid" NOT NULL,
    "history" "jsonb",
    "github_id" "uuid",
    "linear_id" "uuid",
    "pivotal_tracker_id" "uuid"
);

ALTER TABLE "tachio"."orgs" OWNER TO "postgres";

ALTER TABLE "tachio"."orgs" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."partners_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."pivotal_tracker_webhooks" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "kind" "text",
    "guid" "text",
    "project_version" integer,
    "message" "text",
    "highlight" "text",
    "changes" "jsonb"[],
    "primary_resources" "jsonb"[],
    "secondary_resources" "jsonb"[],
    "project_id" bigint NOT NULL,
    "performed_by" "jsonb",
    "occurred_at" timestamp with time zone NOT NULL
);

ALTER TABLE "tachio"."pivotal_tracker_webhooks" OWNER TO "postgres";

ALTER TABLE "tachio"."pivotal_tracker_webhooks" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."pivotal_tracker_webhooks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."projects" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "shortname" "text" NOT NULL,
    "aliases" "text"[],
    "summary" "text",
    "note" "text",
    "org_id" bigint NOT NULL,
    "missive_conversation_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "missive_label_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "start_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "end_date" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "history" "jsonb",
    "status" "tachio"."project_status",
    "linear_team_id" "uuid",
    "pivotal_tracker_id" bigint
);

ALTER TABLE "tachio"."projects" OWNER TO "postgres";

ALTER TABLE "tachio"."projects" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."projects_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."slack_channels" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "tachio"."slack_channels" OWNER TO "postgres";

ALTER TABLE "tachio"."slack_channels" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "tachio"."slack_channels_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "tachio"."table_change_log" (
    "id" integer NOT NULL,
    "command_tag" "text",
    "object_type" "text",
    "schema_name" "text",
    "object_identity" "text",
    "in_extension" boolean,
    "change_timestamp" timestamp without time zone
);

ALTER TABLE "tachio"."table_change_log" OWNER TO "postgres";

CREATE SEQUENCE IF NOT EXISTS "tachio"."table_change_log_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER TABLE "tachio"."table_change_log_id_seq" OWNER TO "postgres";

ALTER SEQUENCE "tachio"."table_change_log_id_seq" OWNED BY "tachio"."table_change_log"."id";

ALTER TABLE ONLY "history"."prompts_history_archive" ALTER COLUMN "id" SET DEFAULT "nextval"('"history"."prompts_history_archive_id_seq"'::"regclass");

ALTER TABLE ONLY "tachio"."table_change_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"tachio"."table_change_log_id_seq"'::"regclass");

ALTER TABLE ONLY "history"."prompts_history_archive"
    ADD CONSTRAINT "prompts_history_archive_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."config"
    ADD CONSTRAINT "config_config_key_key" UNIQUE ("config_key");

ALTER TABLE ONLY "public"."config"
    ADD CONSTRAINT "config_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."memories"
    ADD CONSTRAINT "memories_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."prompts"
    ADD CONSTRAINT "prompts_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."todos"
    ADD CONSTRAINT "todos_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."emails"
    ADD CONSTRAINT "emails_email_address_key" UNIQUE ("email_address");

ALTER TABLE ONLY "tachio"."emails"
    ADD CONSTRAINT "emails_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."github_webhooks"
    ADD CONSTRAINT "github_webhooks_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."linear_projects"
    ADD CONSTRAINT "linear_projects_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."linear_teams"
    ADD CONSTRAINT "linear_teams_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."linear_webhooks"
    ADD CONSTRAINT "linear_webhooks_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."org_emails"
    ADD CONSTRAINT "org_emails_pkey" PRIMARY KEY ("org_id", "email_id");

ALTER TABLE ONLY "tachio"."org_slack_channels"
    ADD CONSTRAINT "org_slack_channels_pkey" PRIMARY KEY ("org_id", "slack_channel_id");

ALTER TABLE ONLY "tachio"."orgs"
    ADD CONSTRAINT "orgs_name_key" UNIQUE ("name");

ALTER TABLE ONLY "tachio"."orgs"
    ADD CONSTRAINT "partners_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."orgs"
    ADD CONSTRAINT "partners_shortname_key" UNIQUE ("shortname");

ALTER TABLE ONLY "tachio"."pivotal_tracker_webhooks"
    ADD CONSTRAINT "pivotal_tracker_webhooks_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."projects"
    ADD CONSTRAINT "projects_linear_team_id_unique" UNIQUE ("linear_team_id");

ALTER TABLE ONLY "tachio"."projects"
    ADD CONSTRAINT "projects_name_unique" UNIQUE ("name");

ALTER TABLE ONLY "tachio"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."slack_channels"
    ADD CONSTRAINT "slack_channels_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "tachio"."table_change_log"
    ADD CONSTRAINT "table_change_log_pkey" PRIMARY KEY ("id");

CREATE OR REPLACE TRIGGER "trg_record_prompt_history" BEFORE INSERT OR UPDATE ON "public"."prompts" FOR EACH ROW EXECUTE FUNCTION "public"."fn_record_prompt_history"();

CREATE OR REPLACE TRIGGER "update_dimensions_modtime" BEFORE UPDATE ON "public"."prompts" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_column"();

CREATE OR REPLACE TRIGGER "handle_updated_at_github_webhook" BEFORE UPDATE ON "tachio"."github_webhooks" FOR EACH ROW EXECUTE FUNCTION "extensions"."moddatetime"('updated_at');

CREATE OR REPLACE TRIGGER "handle_updated_at_linear_project" BEFORE UPDATE ON "tachio"."linear_projects" FOR EACH ROW EXECUTE FUNCTION "extensions"."moddatetime"('updated_at');

CREATE OR REPLACE TRIGGER "handle_updated_at_linear_team" BEFORE UPDATE ON "tachio"."linear_teams" FOR EACH ROW EXECUTE FUNCTION "extensions"."moddatetime"('updated_at');

CREATE OR REPLACE TRIGGER "handle_updated_at_linear_webhook" BEFORE UPDATE ON "tachio"."linear_webhooks" FOR EACH ROW EXECUTE FUNCTION "extensions"."moddatetime"('updated_at');

CREATE OR REPLACE TRIGGER "handle_updated_at_org" BEFORE UPDATE ON "tachio"."orgs" FOR EACH ROW EXECUTE FUNCTION "extensions"."moddatetime"('updated_at');

CREATE OR REPLACE TRIGGER "handle_updated_at_project" BEFORE UPDATE ON "tachio"."projects" FOR EACH ROW EXECUTE FUNCTION "extensions"."moddatetime"('updated_at');

CREATE OR REPLACE TRIGGER "store_org_history" BEFORE UPDATE ON "tachio"."orgs" FOR EACH ROW EXECUTE FUNCTION "tachio"."store_history"();

CREATE OR REPLACE TRIGGER "store_project_history" BEFORE UPDATE ON "tachio"."projects" FOR EACH ROW EXECUTE FUNCTION "tachio"."store_history"();

ALTER TABLE ONLY "history"."prompts_history_archive"
    ADD CONSTRAINT "prompts_history_archive_prompt_id_fkey" FOREIGN KEY ("prompt_id") REFERENCES "public"."prompts"("id");

ALTER TABLE ONLY "tachio"."linear_projects"
    ADD CONSTRAINT "tachio_linear_projects_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "tachio"."projects"("linear_team_id") ON DELETE SET NULL;

ALTER TABLE ONLY "tachio"."linear_webhooks"
    ADD CONSTRAINT "tachio_linear_webhooks_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "tachio"."linear_projects"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "tachio"."linear_webhooks"
    ADD CONSTRAINT "tachio_linear_webhooks_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "tachio"."projects"("linear_team_id") ON DELETE SET NULL;

ALTER TABLE ONLY "tachio"."org_emails"
    ADD CONSTRAINT "tachio_org_emails_email_id_fkey" FOREIGN KEY ("email_id") REFERENCES "tachio"."emails"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "tachio"."org_emails"
    ADD CONSTRAINT "tachio_org_emails_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "tachio"."orgs"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "tachio"."org_slack_channels"
    ADD CONSTRAINT "tachio_org_slack_channels_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "tachio"."orgs"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "tachio"."org_slack_channels"
    ADD CONSTRAINT "tachio_org_slack_channels_slack_channel_id_fkey" FOREIGN KEY ("slack_channel_id") REFERENCES "tachio"."slack_channels"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "tachio"."orgs"
    ADD CONSTRAINT "tachio_orgs_primary_email_address_fkey" FOREIGN KEY ("primary_email_address") REFERENCES "tachio"."emails"("email_address") ON DELETE SET NULL;

ALTER TABLE ONLY "tachio"."orgs"
    ADD CONSTRAINT "tachio_orgs_primary_slack_channel_id_fkey" FOREIGN KEY ("primary_slack_channel_id") REFERENCES "tachio"."slack_channels"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "tachio"."projects"
    ADD CONSTRAINT "tachio_projects_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "tachio"."orgs"("id") ON DELETE CASCADE;

ALTER TABLE "history"."prompts_history_archive" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable insert for authenticated users only" ON "public"."prompts" FOR INSERT TO "authenticated" WITH CHECK (true);

CREATE POLICY "Enable read access for all users" ON "public"."messages" FOR SELECT USING (true);

ALTER TABLE "public"."prompts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."emails" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."github_webhooks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."linear_projects" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."linear_teams" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."linear_webhooks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."org_emails" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."org_slack_channels" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."orgs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."pivotal_tracker_webhooks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."projects" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "tachio"."slack_channels" ENABLE ROW LEVEL SECURITY;

ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

GRANT USAGE ON SCHEMA "tachio" TO "anon";
GRANT USAGE ON SCHEMA "tachio" TO "authenticated";
GRANT USAGE ON SCHEMA "tachio" TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

GRANT ALL ON FUNCTION "public"."archive_history_based_on_version_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."archive_history_based_on_version_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."archive_history_based_on_version_count"() TO "service_role";

GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."fn_record_prompt_history"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_record_prompt_history"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_record_prompt_history"() TO "service_role";

GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";

GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";

GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."match_memories"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."match_memories"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_memories"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "tachio"."store_history"() TO "anon";
GRANT ALL ON FUNCTION "tachio"."store_history"() TO "authenticated";
GRANT ALL ON FUNCTION "tachio"."store_history"() TO "service_role";

GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";

GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

GRANT ALL ON TABLE "history"."prompts_history_archive" TO "anon";
GRANT ALL ON TABLE "history"."prompts_history_archive" TO "authenticated";
GRANT ALL ON TABLE "history"."prompts_history_archive" TO "service_role";

GRANT ALL ON SEQUENCE "history"."prompts_history_archive_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "history"."prompts_history_archive_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "history"."prompts_history_archive_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."config" TO "anon";
GRANT ALL ON TABLE "public"."config" TO "authenticated";
GRANT ALL ON TABLE "public"."config" TO "service_role";

GRANT ALL ON SEQUENCE "public"."config_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."config_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."config_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."memories" TO "anon";
GRANT ALL ON TABLE "public"."memories" TO "authenticated";
GRANT ALL ON TABLE "public"."memories" TO "service_role";

GRANT ALL ON SEQUENCE "public"."memories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."memories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."memories_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";

GRANT ALL ON SEQUENCE "public"."messages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."messages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."messages_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."prompts" TO "anon";
GRANT ALL ON TABLE "public"."prompts" TO "authenticated";
GRANT ALL ON TABLE "public"."prompts" TO "service_role";

GRANT ALL ON SEQUENCE "public"."prompts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."prompts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."prompts_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."todos" TO "anon";
GRANT ALL ON TABLE "public"."todos" TO "authenticated";
GRANT ALL ON TABLE "public"."todos" TO "service_role";

GRANT ALL ON SEQUENCE "public"."todos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."todos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."todos_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."emails" TO "anon";
GRANT ALL ON TABLE "tachio"."emails" TO "authenticated";
GRANT ALL ON TABLE "tachio"."emails" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."emails_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."emails_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."emails_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."github_webhooks" TO "anon";
GRANT ALL ON TABLE "tachio"."github_webhooks" TO "authenticated";
GRANT ALL ON TABLE "tachio"."github_webhooks" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."github_webhooks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."github_webhooks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."github_webhooks_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."linear_projects" TO "anon";
GRANT ALL ON TABLE "tachio"."linear_projects" TO "authenticated";
GRANT ALL ON TABLE "tachio"."linear_projects" TO "service_role";

GRANT ALL ON TABLE "tachio"."linear_teams" TO "anon";
GRANT ALL ON TABLE "tachio"."linear_teams" TO "authenticated";
GRANT ALL ON TABLE "tachio"."linear_teams" TO "service_role";

GRANT ALL ON TABLE "tachio"."linear_webhooks" TO "anon";
GRANT ALL ON TABLE "tachio"."linear_webhooks" TO "authenticated";
GRANT ALL ON TABLE "tachio"."linear_webhooks" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."linear_webhooks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."linear_webhooks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."linear_webhooks_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."org_emails" TO "anon";
GRANT ALL ON TABLE "tachio"."org_emails" TO "authenticated";
GRANT ALL ON TABLE "tachio"."org_emails" TO "service_role";

GRANT ALL ON TABLE "tachio"."org_slack_channels" TO "anon";
GRANT ALL ON TABLE "tachio"."org_slack_channels" TO "authenticated";
GRANT ALL ON TABLE "tachio"."org_slack_channels" TO "service_role";

GRANT ALL ON TABLE "tachio"."orgs" TO "anon";
GRANT ALL ON TABLE "tachio"."orgs" TO "authenticated";
GRANT ALL ON TABLE "tachio"."orgs" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."partners_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."partners_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."partners_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."pivotal_tracker_webhooks" TO "anon";
GRANT ALL ON TABLE "tachio"."pivotal_tracker_webhooks" TO "authenticated";
GRANT ALL ON TABLE "tachio"."pivotal_tracker_webhooks" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."pivotal_tracker_webhooks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."pivotal_tracker_webhooks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."pivotal_tracker_webhooks_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."projects" TO "anon";
GRANT ALL ON TABLE "tachio"."projects" TO "authenticated";
GRANT ALL ON TABLE "tachio"."projects" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."projects_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."projects_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."projects_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."slack_channels" TO "anon";
GRANT ALL ON TABLE "tachio"."slack_channels" TO "authenticated";
GRANT ALL ON TABLE "tachio"."slack_channels" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."slack_channels_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."slack_channels_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."slack_channels_id_seq" TO "service_role";

GRANT ALL ON TABLE "tachio"."table_change_log" TO "anon";
GRANT ALL ON TABLE "tachio"."table_change_log" TO "authenticated";
GRANT ALL ON TABLE "tachio"."table_change_log" TO "service_role";

GRANT ALL ON SEQUENCE "tachio"."table_change_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "tachio"."table_change_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "tachio"."table_change_log_id_seq" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON SEQUENCES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON FUNCTIONS  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tachio" GRANT ALL ON TABLES  TO "service_role";

RESET ALL;
