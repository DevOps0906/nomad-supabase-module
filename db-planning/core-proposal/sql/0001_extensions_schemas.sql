-- 0001: extensions & schemas
create extension if not exists pgcrypto;
create extension if not exists vector;

create schema if not exists core;

do $$ begin
  create type core.org_type as enum ('personal','team');
exception when duplicate_object then null; end $$;

do $$ begin
  create type core.member_role as enum ('owner','admin','member','viewer','billing');
exception when duplicate_object then null; end $$;

-- rollback: drop schema core cascade;
