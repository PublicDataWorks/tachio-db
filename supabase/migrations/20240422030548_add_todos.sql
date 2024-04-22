grant delete on table "public"."config" to "postgres";

grant insert on table "public"."config" to "postgres";

grant references on table "public"."config" to "postgres";

grant select on table "public"."config" to "postgres";

grant trigger on table "public"."config" to "postgres";

grant truncate on table "public"."config" to "postgres";

grant update on table "public"."config" to "postgres";

grant delete on table "public"."memories" to "postgres";

grant insert on table "public"."memories" to "postgres";

grant references on table "public"."memories" to "postgres";

grant select on table "public"."memories" to "postgres";

grant trigger on table "public"."memories" to "postgres";

grant truncate on table "public"."memories" to "postgres";

grant update on table "public"."memories" to "postgres";

grant delete on table "public"."messages" to "postgres";

grant insert on table "public"."messages" to "postgres";

grant references on table "public"."messages" to "postgres";

grant select on table "public"."messages" to "postgres";

grant trigger on table "public"."messages" to "postgres";

grant truncate on table "public"."messages" to "postgres";

grant update on table "public"."messages" to "postgres";

grant delete on table "public"."prompts" to "postgres";

grant insert on table "public"."prompts" to "postgres";

grant references on table "public"."prompts" to "postgres";

grant select on table "public"."prompts" to "postgres";

grant trigger on table "public"."prompts" to "postgres";

grant truncate on table "public"."prompts" to "postgres";

grant update on table "public"."prompts" to "postgres";

grant delete on table "public"."todos" to "postgres";

grant insert on table "public"."todos" to "postgres";

grant references on table "public"."todos" to "postgres";

grant select on table "public"."todos" to "postgres";

grant trigger on table "public"."todos" to "postgres";

grant truncate on table "public"."todos" to "postgres";

grant update on table "public"."todos" to "postgres";


create type "tachio"."todo_priority" as enum ('now', 'next', 'later');

create type "tachio"."todo_status" as enum ('done', 'in_progress', 'todo', 'icebox');

create table "tachio"."todos" (
    "id" bigint generated by default as identity not null,
    "created_at" timestamp with time zone not null default now(),
    "project_id" bigint not null,
    "name" text not null,
    "description" text,
    "external_urls" text[],
    "completed_at" timestamp with time zone,
    "status" tachio.todo_status,
    "priority" tachio.todo_priority,
    "updated_at" timestamp with time zone not null default now()
);


alter table "tachio"."todos" enable row level security;

CREATE UNIQUE INDEX todos_pkey ON tachio.todos USING btree (id);

alter table "tachio"."todos" add constraint "todos_pkey" PRIMARY KEY using index "todos_pkey";

alter table "tachio"."todos" add constraint "tachio_todos_project_id_fkey" FOREIGN KEY (project_id) REFERENCES tachio.projects(id) ON DELETE CASCADE not valid;

alter table "tachio"."todos" validate constraint "tachio_todos_project_id_fkey";

CREATE TRIGGER handle_updated_at_todo BEFORE UPDATE ON tachio.todos FOR EACH ROW EXECUTE FUNCTION moddatetime('updated_at');

