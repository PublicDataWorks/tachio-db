CREATE SCHEMA "tachio";
CREATE EXTENSION IF NOT EXISTS moddatetime SCHEMA "tachio";

--> statement-breakpoint
DO $$ BEGIN
CREATE TYPE "tachio"."project_status" AS ENUM('active', 'paused', 'completed', 'archived');
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."emails" (
	"id" bigint PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"email_address" text NOT NULL,
	CONSTRAINT "emails_email_address_key" UNIQUE("email_address")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."orgs" (
	"id" bigint PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"name" text NOT NULL,
	"shortname" text NOT NULL,
	"aliases" text[],
	"first_contact" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"website" text,
	"primary_email_address" text,
	"primary_slack_channel_id" bigint,
	"summary" text,
	"note" text,
	"missive_conversation_id" uuid NOT NULL,
	"missive_label_id" uuid NOT NULL,
	"history" jsonb,
	CONSTRAINT "orgs_name_key" UNIQUE("name"),
	CONSTRAINT "partners_shortname_key" UNIQUE("shortname")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."slack_channels" (
	"id" bigint PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."projects" (
	"id" bigint PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"name" text NOT NULL,
	"shortname" text NOT NULL,
	"aliases" text[],
	"summary" text,
	"note" text,
	"org_id" bigint NOT NULL,
	"missive_conversation_id" uuid DEFAULT gen_random_uuid() NOT NULL,
	"missive_label_id" uuid DEFAULT gen_random_uuid() NOT NULL,
	"start_date" timestamp with time zone DEFAULT now() NOT NULL,
	"end_date" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"history" jsonb,
	"status" "tachio"."project_status",
	CONSTRAINT "projects_name_key" UNIQUE("name"),
	CONSTRAINT "projects_shortname_key" UNIQUE("shortname")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."table_change_log" (
	"id" serial PRIMARY KEY NOT NULL,
	"command_tag" text,
	"object_type" text,
	"schema_name" text,
	"object_identity" text,
	"in_extension" boolean,
	"change_timestamp" timestamp
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."org_emails" (
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"org_id" bigint NOT NULL,
	"email_id" bigint NOT NULL,
	CONSTRAINT "org_emails_pkey" PRIMARY KEY("org_id","email_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tachio"."org_slack_channels" (
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"org_id" bigint NOT NULL,
	"slack_channel_id" bigint NOT NULL,
	CONSTRAINT "org_slack_channels_pkey" PRIMARY KEY("org_id","slack_channel_id")
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."orgs" ADD CONSTRAINT "tachio_orgs_primary_email_address_fkey" FOREIGN KEY ("primary_email_address") REFERENCES "tachio"."emails"("email_address") ON DELETE set null ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."orgs" ADD CONSTRAINT "tachio_orgs_primary_slack_channel_id_fkey" FOREIGN KEY ("primary_slack_channel_id") REFERENCES "tachio"."slack_channels"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."projects" ADD CONSTRAINT "tachio_projects_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "tachio"."orgs"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."org_emails" ADD CONSTRAINT "tachio_org_emails_email_id_fkey" FOREIGN KEY ("email_id") REFERENCES "tachio"."emails"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."org_emails" ADD CONSTRAINT "tachio_org_emails_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "tachio"."orgs"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."org_slack_channels" ADD CONSTRAINT "tachio_org_slack_channels_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "tachio"."orgs"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "tachio"."org_slack_channels" ADD CONSTRAINT "tachio_org_slack_channels_slack_channel_id_fkey" FOREIGN KEY ("slack_channel_id") REFERENCES "tachio"."slack_channels"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;

CREATE OR REPLACE FUNCTION "tachio"."store_history"()
RETURNS TRIGGER AS $$
DECLARE
 old_data JSONB;
BEGIN
 old_data = to_jsonb(OLD) - 'history' - 'created_at';

 IF NEW.history IS NULL THEN
     NEW.history := '[]';
 END IF;
 NEW.history = jsonb_insert(NEW.history, '{-1}', old_data);

 RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgname = 'store_org_history'
    ) THEN
        CREATE TRIGGER "store_org_history"
        BEFORE UPDATE ON "tachio"."orgs"
        FOR EACH ROW
        EXECUTE FUNCTION "tachio"."store_history"();
    END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgname = 'handle_updated_at_org'
    ) THEN
        CREATE TRIGGER "handle_updated_at_org"
        BEFORE UPDATE ON "tachio"."orgs"
        FOR EACH ROW EXECUTE PROCEDURE "tachio".moddatetime (updated_at);
    END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgname = 'store_project_history'
    ) THEN
        CREATE TRIGGER "store_project_history"
        BEFORE UPDATE ON "tachio"."projects"
        FOR EACH ROW
        EXECUTE FUNCTION "tachio"."store_history"();
    END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgname = 'handle_updated_at_project'
    ) THEN
        CREATE TRIGGER "handle_updated_at_project"
        BEFORE UPDATE ON "tachio"."projects"
        FOR EACH ROW EXECUTE PROCEDURE "tachio".moddatetime (updated_at);
    END IF;
END;
$$ LANGUAGE plpgsql;

