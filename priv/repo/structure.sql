--
-- PostgreSQL database dump
--

\restrict HSeE1DNL6ay8AvaUT6JA4yLJldJmoSeQUIr26mixpmG5iV69GNyvIwQUhFi7aKZ

-- Dumped from database version 18.3 (Homebrew)
-- Dumped by pg_dump version 18.3 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: immutable_unaccent(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.immutable_unaccent(text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
  SELECT public.unaccent('public.unaccent', $1)
$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: actors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.actors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    kind character varying(255) DEFAULT 'agent'::character varying NOT NULL,
    display_name character varying(255),
    host character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: api_key_workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_key_workspaces (
    id uuid NOT NULL,
    api_key_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    access_level character varying(255) DEFAULT 'read'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    token_hash character varying(255) NOT NULL,
    token_prefix character varying(255) NOT NULL,
    revoked_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    created_by_user_id bigint,
    actor_id uuid NOT NULL
);


--
-- Name: brain_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brain_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid,
    action character varying(50) NOT NULL,
    subject character varying(500),
    details jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: cluster_summaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cluster_summaries (
    id uuid DEFAULT gen_random_uuid() CONSTRAINT community_summaries_id_not_null NOT NULL,
    workspace_id uuid CONSTRAINT community_summaries_workspace_id_not_null NOT NULL,
    cluster_id integer CONSTRAINT community_summaries_community_id_not_null NOT NULL,
    summary text CONSTRAINT community_summaries_summary_not_null NOT NULL,
    page_count integer DEFAULT 0,
    top_pages jsonb DEFAULT '[]'::jsonb,
    generated_at timestamp(0) without time zone CONSTRAINT community_summaries_generated_at_not_null NOT NULL,
    inserted_at timestamp(0) without time zone CONSTRAINT community_summaries_inserted_at_not_null NOT NULL,
    updated_at timestamp(0) without time zone CONSTRAINT community_summaries_updated_at_not_null NOT NULL
);


--
-- Name: collections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    summary character varying(255),
    filters jsonb DEFAULT '{}'::jsonb,
    workspace_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: knowledge_page_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_page_versions (
    id uuid DEFAULT gen_random_uuid() CONSTRAINT page_versions_id_not_null NOT NULL,
    page_id uuid CONSTRAINT page_versions_page_id_not_null NOT NULL,
    body text CONSTRAINT page_versions_body_not_null NOT NULL,
    body_hash character varying(64),
    version integer CONSTRAINT page_versions_version_not_null NOT NULL,
    changed_by character varying(200),
    inserted_at timestamp(0) without time zone CONSTRAINT page_versions_inserted_at_not_null NOT NULL
);


--
-- Name: knowledge_pages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_pages (
    id uuid DEFAULT gen_random_uuid() CONSTRAINT pages_id_not_null NOT NULL,
    workspace_id uuid CONSTRAINT pages_workspace_id_not_null NOT NULL,
    title character varying(500) CONSTRAINT pages_title_not_null NOT NULL,
    slug character varying(500) CONSTRAINT pages_slug_not_null NOT NULL,
    body text DEFAULT ''::text,
    page_type character varying(50) CONSTRAINT pages_page_type_not_null NOT NULL,
    summary text,
    tags character varying(255)[] DEFAULT ARRAY[]::character varying[],
    meta jsonb DEFAULT '{}'::jsonb,
    kb_confidence character varying(20),
    kb_source_url text,
    kb_contested boolean DEFAULT false CONSTRAINT pages_kb_contested_not_null NOT NULL,
    body_hash character varying(64),
    version integer DEFAULT 1 CONSTRAINT pages_version_not_null NOT NULL,
    inserted_at timestamp(0) without time zone CONSTRAINT pages_inserted_at_not_null NOT NULL,
    updated_at timestamp(0) without time zone CONSTRAINT pages_updated_at_not_null NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('spanish'::regconfig, ((public.immutable_unaccent((COALESCE(title, ''::character varying))::text) || ' '::text) || public.immutable_unaccent(COALESCE(body, ''::text))))) STORED,
    created_by character varying(255) DEFAULT 'system'::character varying CONSTRAINT pages_created_by_not_null NOT NULL,
    updated_by character varying(255),
    on_behalf_of character varying(255),
    embedding_hash character varying(255),
    embedding public.vector(1024),
    archived boolean DEFAULT false CONSTRAINT pages_archived_not_null NOT NULL,
    pinned boolean DEFAULT false CONSTRAINT pages_pinned_not_null NOT NULL
);


--
-- Name: memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    content text NOT NULL,
    content_hash character varying(255) NOT NULL,
    embedding public.vector(1024),
    trust_score real DEFAULT 0.5 NOT NULL,
    helpful_count integer DEFAULT 0 NOT NULL,
    retrieval_count integer DEFAULT 0 NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    source_session character varying(255),
    created_by character varying(255) DEFAULT 'system'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('spanish'::regconfig, public.immutable_unaccent(COALESCE(content, ''::text)))) STORED
);


--
-- Name: relations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_id uuid NOT NULL,
    target_id uuid NOT NULL,
    relation_type character varying(50) DEFAULT 'related'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb,
    weight double precision,
    source_type character varying(255) DEFAULT 'page'::character varying NOT NULL,
    target_type character varying(255) DEFAULT 'page'::character varying NOT NULL
);


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    body character varying(255) DEFAULT ''::character varying,
    report_type character varying(255),
    meta jsonb DEFAULT '{}'::jsonb,
    workspace_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    archived boolean DEFAULT false NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    key character varying(255) NOT NULL,
    value jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    workspace_id uuid
);


--
-- Name: user_workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_workspaces (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    workspace_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    role character varying(255) DEFAULT 'viewer'::character varying NOT NULL
);


--
-- Name: user_workspaces_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_workspaces_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_workspaces_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_workspaces_id_seq OWNED BY public.user_workspaces.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    name character varying(255),
    google_id character varying(255),
    avatar_url character varying(255),
    api_token character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    password_hash character varying(255),
    default_workspace_slug character varying(255),
    is_owner boolean DEFAULT false NOT NULL,
    actor_id uuid
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: worker_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    worker_type character varying(255) NOT NULL,
    input character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    summary text,
    pages_created integer DEFAULT 0,
    steps_count integer DEFAULT 0,
    started_at timestamp(0) without time zone,
    completed_at timestamp(0) without time zone,
    meta jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: worker_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    step_number integer NOT NULL,
    tool_name character varying(255) NOT NULL,
    tool_args jsonb DEFAULT '{}'::jsonb,
    tool_result jsonb DEFAULT '{}'::jsonb,
    reasoning text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    disabled_page_types character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    visibility character varying(255) DEFAULT 'public'::character varying NOT NULL,
    enabled_features jsonb DEFAULT '{}'::jsonb NOT NULL,
    semantic_threshold_short double precision,
    semantic_threshold_mid double precision,
    semantic_threshold_long double precision,
    entity_linker_enabled boolean,
    worker_max_pages integer,
    summary_language character varying(255)
);


--
-- Name: user_workspaces id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_workspaces ALTER COLUMN id SET DEFAULT nextval('public.user_workspaces_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: actors actors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actors
    ADD CONSTRAINT actors_pkey PRIMARY KEY (id);


--
-- Name: api_key_workspaces api_key_workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_workspaces
    ADD CONSTRAINT api_key_workspaces_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: brain_log brain_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brain_log
    ADD CONSTRAINT brain_log_pkey PRIMARY KEY (id);


--
-- Name: collections collections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_pkey PRIMARY KEY (id);


--
-- Name: cluster_summaries community_summaries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_summaries
    ADD CONSTRAINT community_summaries_pkey PRIMARY KEY (id);


--
-- Name: knowledge_page_versions knowledge_page_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_page_versions
    ADD CONSTRAINT knowledge_page_versions_pkey PRIMARY KEY (id);


--
-- Name: knowledge_pages knowledge_pages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_pages
    ADD CONSTRAINT knowledge_pages_pkey PRIMARY KEY (id);


--
-- Name: memories memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_pkey PRIMARY KEY (id);


--
-- Name: relations relations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relations
    ADD CONSTRAINT relations_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (key);


--
-- Name: user_workspaces user_workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_workspaces
    ADD CONSTRAINT user_workspaces_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: worker_sessions worker_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_sessions
    ADD CONSTRAINT worker_sessions_pkey PRIMARY KEY (id);


--
-- Name: worker_steps worker_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_steps
    ADD CONSTRAINT worker_steps_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: actors_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX actors_kind_index ON public.actors USING btree (kind);


--
-- Name: actors_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX actors_name_index ON public.actors USING btree (name);


--
-- Name: api_key_workspaces_api_key_id_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_key_workspaces_api_key_id_workspace_id_index ON public.api_key_workspaces USING btree (api_key_id, workspace_id);


--
-- Name: api_key_workspaces_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_key_workspaces_workspace_id_index ON public.api_key_workspaces USING btree (workspace_id);


--
-- Name: api_keys_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_keys_actor_id_index ON public.api_keys USING btree (actor_id);


--
-- Name: api_keys_created_by_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_keys_created_by_user_id_index ON public.api_keys USING btree (created_by_user_id);


--
-- Name: api_keys_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_keys_token_hash_index ON public.api_keys USING btree (token_hash);


--
-- Name: brain_log_action_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX brain_log_action_index ON public.brain_log USING btree (action);


--
-- Name: brain_log_ctx_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX brain_log_ctx_inserted_at_idx ON public.brain_log USING btree (workspace_id, inserted_at);


--
-- Name: brain_log_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX brain_log_workspace_id_index ON public.brain_log USING btree (workspace_id);


--
-- Name: cluster_summaries_workspace_id_cluster_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cluster_summaries_workspace_id_cluster_id_index ON public.cluster_summaries USING btree (workspace_id, cluster_id);


--
-- Name: collections_workspace_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collections_workspace_id_slug_index ON public.collections USING btree (workspace_id, slug);


--
-- Name: community_summaries_workspace_id_community_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX community_summaries_workspace_id_community_id_index ON public.cluster_summaries USING btree (workspace_id, cluster_id);


--
-- Name: community_summaries_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX community_summaries_workspace_id_index ON public.cluster_summaries USING btree (workspace_id);


--
-- Name: knowledge_page_versions_page_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_page_versions_page_id_index ON public.knowledge_page_versions USING btree (page_id);


--
-- Name: knowledge_page_versions_page_version_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_page_versions_page_version_uidx ON public.knowledge_page_versions USING btree (page_id, version);


--
-- Name: knowledge_page_versions_version_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_page_versions_version_index ON public.knowledge_page_versions USING btree (version);


--
-- Name: knowledge_pages_context_updated_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_context_updated_at_idx ON public.knowledge_pages USING btree (workspace_id, updated_at);


--
-- Name: knowledge_pages_ctx_type_archived_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_ctx_type_archived_idx ON public.knowledge_pages USING btree (workspace_id, page_type, archived);


--
-- Name: knowledge_pages_ctx_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_ctx_type_idx ON public.knowledge_pages USING btree (workspace_id, page_type);


--
-- Name: knowledge_pages_embedding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_embedding_idx ON public.knowledge_pages USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: knowledge_pages_meta_assignee_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_meta_assignee_idx ON public.knowledge_pages USING btree (((meta ->> 'assignee'::text))) WHERE ((meta ->> 'assignee'::text) IS NOT NULL);


--
-- Name: knowledge_pages_meta_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_meta_idx ON public.knowledge_pages USING gin (meta);


--
-- Name: knowledge_pages_meta_kanban_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_meta_kanban_status_idx ON public.knowledge_pages USING btree (((meta ->> 'kanban_status'::text))) WHERE ((meta ->> 'kanban_status'::text) IS NOT NULL);


--
-- Name: knowledge_pages_meta_plan_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_meta_plan_slug_idx ON public.knowledge_pages USING btree (((meta ->> 'plan_slug'::text))) WHERE ((meta ->> 'plan_slug'::text) IS NOT NULL);


--
-- Name: knowledge_pages_meta_project_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_meta_project_slug_idx ON public.knowledge_pages USING btree (((meta ->> 'project_slug'::text))) WHERE ((meta ->> 'project_slug'::text) IS NOT NULL);


--
-- Name: knowledge_pages_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_search_idx ON public.knowledge_pages USING gin (search_vector);


--
-- Name: knowledge_pages_tags_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_tags_idx ON public.knowledge_pages USING gin (tags);


--
-- Name: knowledge_pages_trgm_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_trgm_idx ON public.knowledge_pages USING gin (public.immutable_unaccent((title)::text) public.gin_trgm_ops);


--
-- Name: knowledge_pages_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_type_idx ON public.knowledge_pages USING btree (page_type);


--
-- Name: knowledge_pages_workspace_id_archived_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_workspace_id_archived_index ON public.knowledge_pages USING btree (workspace_id, archived);


--
-- Name: knowledge_pages_workspace_id_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_workspace_id_slug_idx ON public.knowledge_pages USING btree (workspace_id, slug);


--
-- Name: knowledge_pages_workspace_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_pages_workspace_id_slug_index ON public.knowledge_pages USING btree (workspace_id, slug);


--
-- Name: knowledge_pages_ws_slug_word_start_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_ws_slug_word_start_idx ON public.knowledge_pages USING btree (workspace_id, lower((slug)::text) text_pattern_ops);


--
-- Name: knowledge_pages_ws_title_word_start_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_pages_ws_title_word_start_idx ON public.knowledge_pages USING btree (workspace_id, lower((title)::text) text_pattern_ops);


--
-- Name: memories_embedding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_embedding_idx ON public.memories USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: memories_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_search_idx ON public.memories USING gin (search_vector);


--
-- Name: memories_workspace_content_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX memories_workspace_content_hash_idx ON public.memories USING btree (workspace_id, content_hash);


--
-- Name: memories_workspace_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_workspace_status_idx ON public.memories USING btree (workspace_id, status);


--
-- Name: relations_source_id_source_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relations_source_id_source_type_index ON public.relations USING btree (source_id, source_type);


--
-- Name: relations_source_id_target_id_relation_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX relations_source_id_target_id_relation_type_index ON public.relations USING btree (source_id, target_id, relation_type);


--
-- Name: relations_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relations_source_idx ON public.relations USING btree (source_id);


--
-- Name: relations_target_id_target_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relations_target_id_target_type_index ON public.relations USING btree (target_id, target_type);


--
-- Name: relations_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relations_target_idx ON public.relations USING btree (target_id);


--
-- Name: reports_workspace_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reports_workspace_id_slug_index ON public.reports USING btree (workspace_id, slug);


--
-- Name: settings_key_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX settings_key_workspace_id_index ON public.settings USING btree (key, COALESCE(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid));


--
-- Name: user_workspaces_role_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_workspaces_role_index ON public.user_workspaces USING btree (role);


--
-- Name: user_workspaces_user_id_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_workspaces_user_id_workspace_id_index ON public.user_workspaces USING btree (user_id, workspace_id);


--
-- Name: users_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_actor_id_index ON public.users USING btree (actor_id);


--
-- Name: users_api_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_api_token_index ON public.users USING btree (api_token);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_google_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_google_id_index ON public.users USING btree (google_id);


--
-- Name: worker_sessions_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX worker_sessions_status_index ON public.worker_sessions USING btree (status);


--
-- Name: worker_sessions_worker_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX worker_sessions_worker_type_index ON public.worker_sessions USING btree (worker_type);


--
-- Name: worker_sessions_workspace_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX worker_sessions_workspace_id_index ON public.worker_sessions USING btree (workspace_id);


--
-- Name: worker_steps_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX worker_steps_session_id_index ON public.worker_steps USING btree (session_id);


--
-- Name: worker_steps_session_id_step_number_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX worker_steps_session_id_step_number_index ON public.worker_steps USING btree (session_id, step_number);


--
-- Name: workspaces_is_default_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspaces_is_default_index ON public.workspaces USING btree (is_default) WHERE (is_default = true);


--
-- Name: workspaces_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspaces_name_index ON public.workspaces USING btree (name);


--
-- Name: workspaces_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspaces_slug_index ON public.workspaces USING btree (slug);


--
-- Name: api_key_workspaces api_key_workspaces_api_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_workspaces
    ADD CONSTRAINT api_key_workspaces_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;


--
-- Name: api_key_workspaces api_key_workspaces_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_workspaces
    ADD CONSTRAINT api_key_workspaces_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: api_keys api_keys_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.actors(id) ON DELETE RESTRICT;


--
-- Name: api_keys api_keys_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: brain_log brain_log_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brain_log
    ADD CONSTRAINT brain_log_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE SET NULL;


--
-- Name: collections collections_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: cluster_summaries community_summaries_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_summaries
    ADD CONSTRAINT community_summaries_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: knowledge_page_versions knowledge_page_versions_page_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_page_versions
    ADD CONSTRAINT knowledge_page_versions_page_id_fkey FOREIGN KEY (page_id) REFERENCES public.knowledge_pages(id) ON DELETE CASCADE;


--
-- Name: knowledge_pages knowledge_pages_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_pages
    ADD CONSTRAINT knowledge_pages_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memories memories_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: reports reports_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: user_workspaces user_workspaces_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_workspaces
    ADD CONSTRAINT user_workspaces_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_workspaces user_workspaces_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_workspaces
    ADD CONSTRAINT user_workspaces_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: users users_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.actors(id) ON DELETE SET NULL;


--
-- Name: worker_sessions worker_sessions_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_sessions
    ADD CONSTRAINT worker_sessions_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: worker_steps worker_steps_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_steps
    ADD CONSTRAINT worker_steps_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.worker_sessions(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict HSeE1DNL6ay8AvaUT6JA4yLJldJmoSeQUIr26mixpmG5iV69GNyvIwQUhFi7aKZ

INSERT INTO public."schema_migrations" (version) VALUES (0);
INSERT INTO public."schema_migrations" (version) VALUES (1);
INSERT INTO public."schema_migrations" (version) VALUES (2);
INSERT INTO public."schema_migrations" (version) VALUES (3);
INSERT INTO public."schema_migrations" (version) VALUES (4);
INSERT INTO public."schema_migrations" (version) VALUES (5);
INSERT INTO public."schema_migrations" (version) VALUES (6);
INSERT INTO public."schema_migrations" (version) VALUES (20260624064220);
INSERT INTO public."schema_migrations" (version) VALUES (20260624151941);
INSERT INTO public."schema_migrations" (version) VALUES (20260625063319);
INSERT INTO public."schema_migrations" (version) VALUES (20260717065537);
INSERT INTO public."schema_migrations" (version) VALUES (20260717083709);
INSERT INTO public."schema_migrations" (version) VALUES (20260717085406);
INSERT INTO public."schema_migrations" (version) VALUES (20260717090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260718021654);
INSERT INTO public."schema_migrations" (version) VALUES (20260719154347);
INSERT INTO public."schema_migrations" (version) VALUES (20260722000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260722000002);
INSERT INTO public."schema_migrations" (version) VALUES (20260802000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260802000002);
INSERT INTO public."schema_migrations" (version) VALUES (20260803000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260803015130);
INSERT INTO public."schema_migrations" (version) VALUES (20260805034223);
INSERT INTO public."schema_migrations" (version) VALUES (20260808000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260808061633);
INSERT INTO public."schema_migrations" (version) VALUES (20260811053234);
INSERT INTO public."schema_migrations" (version) VALUES (20260811220711);
INSERT INTO public."schema_migrations" (version) VALUES (20260812000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260813000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260819165200);
INSERT INTO public."schema_migrations" (version) VALUES (20260820034206);
INSERT INTO public."schema_migrations" (version) VALUES (20260820034235);
INSERT INTO public."schema_migrations" (version) VALUES (20260820044428);
INSERT INTO public."schema_migrations" (version) VALUES (20260820070328);
INSERT INTO public."schema_migrations" (version) VALUES (20260820070329);
INSERT INTO public."schema_migrations" (version) VALUES (20260820070330);
INSERT INTO public."schema_migrations" (version) VALUES (20260820070331);
INSERT INTO public."schema_migrations" (version) VALUES (20260820070332);
INSERT INTO public."schema_migrations" (version) VALUES (20260820070333);
INSERT INTO public."schema_migrations" (version) VALUES (20260820071215);
INSERT INTO public."schema_migrations" (version) VALUES (20260820121111);
INSERT INTO public."schema_migrations" (version) VALUES (20260820125652);
INSERT INTO public."schema_migrations" (version) VALUES (20260820165002);
INSERT INTO public."schema_migrations" (version) VALUES (20260821130005);
INSERT INTO public."schema_migrations" (version) VALUES (20260822225806);
INSERT INTO public."schema_migrations" (version) VALUES (20260823221910);
INSERT INTO public."schema_migrations" (version) VALUES (20260826060202);
INSERT INTO public."schema_migrations" (version) VALUES (20260826061747);
INSERT INTO public."schema_migrations" (version) VALUES (20260826063500);
INSERT INTO public."schema_migrations" (version) VALUES (20260826072217);
INSERT INTO public."schema_migrations" (version) VALUES (20260829232922);
INSERT INTO public."schema_migrations" (version) VALUES (20260901062734);
INSERT INTO public."schema_migrations" (version) VALUES (20260902014536);
INSERT INTO public."schema_migrations" (version) VALUES (20260902032520);
INSERT INTO public."schema_migrations" (version) VALUES (20260902071734);
INSERT INTO public."schema_migrations" (version) VALUES (20260903012226);
INSERT INTO public."schema_migrations" (version) VALUES (20260903012228);
INSERT INTO public."schema_migrations" (version) VALUES (20260903035725);
INSERT INTO public."schema_migrations" (version) VALUES (20260903200000);
INSERT INTO public."schema_migrations" (version) VALUES (20260903213244);
INSERT INTO public."schema_migrations" (version) VALUES (20260903213245);
INSERT INTO public."schema_migrations" (version) VALUES (20260903231528);
INSERT INTO public."schema_migrations" (version) VALUES (20260903231529);
INSERT INTO public."schema_migrations" (version) VALUES (20260904003233);
INSERT INTO public."schema_migrations" (version) VALUES (20260904013000);
INSERT INTO public."schema_migrations" (version) VALUES (20260904120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260904130000);
INSERT INTO public."schema_migrations" (version) VALUES (20260905230811);
INSERT INTO public."schema_migrations" (version) VALUES (20260906002054);
INSERT INTO public."schema_migrations" (version) VALUES (20260906002055);
INSERT INTO public."schema_migrations" (version) VALUES (20260906080000);
INSERT INTO public."schema_migrations" (version) VALUES (20260907215215);
INSERT INTO public."schema_migrations" (version) VALUES (20260907220007);
INSERT INTO public."schema_migrations" (version) VALUES (20260907234045);
INSERT INTO public."schema_migrations" (version) VALUES (20260908001115);
INSERT INTO public."schema_migrations" (version) VALUES (20260908035014);
INSERT INTO public."schema_migrations" (version) VALUES (20260908035020);
INSERT INTO public."schema_migrations" (version) VALUES (20260908054110);
INSERT INTO public."schema_migrations" (version) VALUES (20260909002001);
INSERT INTO public."schema_migrations" (version) VALUES (20260909054747);
INSERT INTO public."schema_migrations" (version) VALUES (20260909072119);
INSERT INTO public."schema_migrations" (version) VALUES (20260912053941);
INSERT INTO public."schema_migrations" (version) VALUES (20260912235428);
INSERT INTO public."schema_migrations" (version) VALUES (20260913001600);
