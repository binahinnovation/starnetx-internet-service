# 📤 How to Export Your Complete Supabase Schema

## Method 1: Using Supabase Dashboard (Easiest)

### Step 1: Export the Complete Schema
1. Go to your existing Supabase project dashboard
2. Navigate to **SQL Editor**
3. Run this query to export EVERYTHING:

```sql
-- ============================================
-- EXPORT COMPLETE DATABASE SCHEMA
-- ============================================

-- This will generate the complete DDL for all your tables, policies, functions, etc.
SELECT 
    'CREATE TABLE IF NOT EXISTS ' || schemaname || '.' || tablename || ' (' || chr(10) ||
    array_to_string(
        array_agg(
            '  ' || column_name || ' ' || 
            data_type || 
            CASE 
                WHEN character_maximum_length IS NOT NULL 
                THEN '(' || character_maximum_length || ')'
                WHEN numeric_precision IS NOT NULL 
                THEN '(' || numeric_precision || ',' || numeric_scale || ')'
                ELSE ''
            END ||
            CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END ||
            CASE WHEN column_default IS NOT NULL THEN ' DEFAULT ' || column_default ELSE '' END
        ), ',' || chr(10)
    ) || chr(10) || ');'
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY schemaname, tablename
ORDER BY tablename;
```

### Step 2: Use pg_dump (Most Complete Method)

If you have access to the database connection string:

1. Go to **Settings** → **Database**
2. Copy your database URI (it looks like: `postgresql://postgres:[password]@[host]:[port]/postgres`)
3. Use this command in your terminal:

```bash
# Export schema only (no data)
pg_dump "your-database-uri" --schema-only --no-owner --no-privileges > complete_schema.sql

# Export schema with RLS policies
pg_dump "your-database-uri" --schema-only --no-owner --no-privileges --no-tablespaces > schema_with_rls.sql

# Export everything including data
pg_dump "your-database-uri" --no-owner --no-privileges > complete_backup.sql
```

## Method 2: Using Supabase CLI (Recommended)

### Step 1: Install Supabase CLI
```bash
npm install -g supabase
```

### Step 2: Link to Your Existing Project
```bash
# Initialize in your project directory
supabase init

# Link to your existing project
supabase link --project-ref your-project-ref
# (You can find project-ref in Settings → General)
```

### Step 3: Pull the Remote Schema
```bash
# This will download all your database objects
supabase db pull

# This creates migration files in supabase/migrations/
```

### Step 4: Push to New Project
```bash
# Create new project and link it
supabase link --project-ref new-project-ref

# Push the schema to new project
supabase db push
```

## Method 3: Manual Export via SQL Editor

Run these queries in your SQL Editor to get everything:

### 1. Export All Tables with Columns
```sql
-- Get CREATE TABLE statements for all tables
WITH table_ddl AS (
  SELECT 
    'CREATE TABLE IF NOT EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ' (' AS start_line,
    c.relname as table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' 
    AND n.nspname = 'public'
),
columns_ddl AS (
  SELECT 
    table_name,
    string_agg(
      '  ' || quote_ident(column_name) || ' ' || 
      CASE 
        WHEN data_type = 'character varying' THEN 'VARCHAR' || '(' || character_maximum_length || ')'
        WHEN data_type = 'numeric' THEN 'NUMERIC' || '(' || numeric_precision || ',' || numeric_scale || ')'
        ELSE UPPER(data_type)
      END ||
      CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END ||
      CASE WHEN column_default IS NOT NULL THEN ' DEFAULT ' || column_default ELSE '' END,
      ',' || E'\n'
      ORDER BY ordinal_position
    ) AS columns_def
  FROM information_schema.columns
  WHERE table_schema = 'public'
  GROUP BY table_name
)
SELECT 
  t.start_line || E'\n' || 
  c.columns_def || E'\n' || 
  ');' || E'\n\n' AS create_statement
FROM table_ddl t
JOIN columns_ddl c ON t.table_name = c.table_name
ORDER BY t.table_name;
```

### 2. Export All Indexes
```sql
-- Get all indexes
SELECT indexdef || ';'
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
```

### 3. Export All Foreign Keys
```sql
-- Get all foreign key constraints
SELECT 
  'ALTER TABLE ' || quote_ident(nsp.nspname) || '.' || quote_ident(tab.relname) || 
  ' ADD CONSTRAINT ' || quote_ident(con.conname) || 
  ' FOREIGN KEY (' || 
  string_agg(quote_ident(att.attname), ', ' ORDER BY conkey.ordinality) || 
  ') REFERENCES ' || 
  quote_ident(fnsp.nspname) || '.' || quote_ident(ftab.relname) || 
  ' (' || 
  string_agg(quote_ident(fatt.attname), ', ' ORDER BY confkey.ordinality) || 
  ')' ||
  CASE 
    WHEN con.confupdtype = 'c' THEN ' ON UPDATE CASCADE'
    WHEN con.confupdtype = 'r' THEN ' ON UPDATE RESTRICT'
    ELSE ''
  END ||
  CASE 
    WHEN con.confdeltype = 'c' THEN ' ON DELETE CASCADE'
    WHEN con.confdeltype = 'r' THEN ' ON DELETE RESTRICT'
    ELSE ''
  END || ';' AS add_constraint
FROM pg_constraint con
  CROSS JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS conkey(attnum, ordinality)
  CROSS JOIN LATERAL unnest(con.confkey) WITH ORDINALITY AS confkey(attnum, ordinality)
  JOIN pg_class tab ON tab.oid = con.conrelid
  JOIN pg_namespace nsp ON nsp.oid = tab.relnamespace
  JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = conkey.attnum
  JOIN pg_class ftab ON ftab.oid = con.confrelid
  JOIN pg_namespace fnsp ON fnsp.oid = ftab.relnamespace
  JOIN pg_attribute fatt ON fatt.attrelid = con.confrelid AND fatt.attnum = confkey.attnum
WHERE con.contype = 'f'
  AND nsp.nspname = 'public'
  AND conkey.ordinality = confkey.ordinality
GROUP BY nsp.nspname, tab.relname, con.conname, fnsp.nspname, ftab.relname, 
         con.confupdtype, con.confdeltype
ORDER BY nsp.nspname, tab.relname, con.conname;
```

### 4. Export All RLS Policies
```sql
-- Get all RLS policies
SELECT 
  'CREATE POLICY ' || quote_ident(policyname) || 
  ' ON ' || quote_ident(schemaname) || '.' || quote_ident(tablename) ||
  ' AS ' || CASE WHEN permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END ||
  ' FOR ' || cmd ||
  ' TO ' || array_to_string(roles, ', ') ||
  CASE WHEN qual IS NOT NULL THEN ' USING (' || qual || ')' ELSE '' END ||
  CASE WHEN with_check IS NOT NULL THEN ' WITH CHECK (' || with_check || ')' ELSE '' END || ';'
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
```

### 5. Export All Functions
```sql
-- Get all functions
SELECT 
  'CREATE OR REPLACE FUNCTION ' || 
  quote_ident(n.nspname) || '.' || quote_ident(p.proname) || 
  '(' || pg_get_function_arguments(p.oid) || ')' ||
  ' RETURNS ' || pg_get_function_result(p.oid) ||
  ' LANGUAGE ' || l.lanname ||
  CASE WHEN p.prosecdef THEN ' SECURITY DEFINER' ELSE '' END ||
  ' AS $func$' || E'\n' || p.prosrc || E'\n' || '$func$;'
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname = 'public'
  AND l.lanname IN ('plpgsql', 'sql')
ORDER BY p.proname;
```

### 6. Export All Triggers
```sql
-- Get all triggers
SELECT 
  'CREATE TRIGGER ' || quote_ident(trigger_name) || 
  ' ' || action_timing || ' ' || 
  string_agg(event_manipulation, ' OR ' ORDER BY event_manipulation) ||
  ' ON ' || quote_ident(event_object_schema) || '.' || quote_ident(event_object_table) ||
  ' FOR EACH ' || action_orientation ||
  ' EXECUTE FUNCTION ' || action_statement || ';'
FROM information_schema.triggers
WHERE event_object_schema = 'public'
GROUP BY trigger_name, action_timing, event_object_schema, 
         event_object_table, action_orientation, action_statement
ORDER BY event_object_table, trigger_name;
```

### 7. Export RLS Status
```sql
-- Check which tables have RLS enabled
SELECT 
  'ALTER TABLE ' || quote_ident(schemaname) || '.' || quote_ident(tablename) || 
  ' ENABLE ROW LEVEL SECURITY;'
FROM pg_tables
WHERE schemaname = 'public' 
  AND rowsecurity = true
ORDER BY tablename;
```

## Method 4: Quick Export Script

Save and run this complete export script in your SQL Editor:

```sql
-- ============================================
-- COMPLETE SCHEMA EXPORT SCRIPT
-- Run this in your existing Supabase SQL Editor
-- Copy the output and save it as a .sql file
-- ============================================

-- Start transaction
BEGIN;

-- Create a temporary function to export everything
CREATE OR REPLACE FUNCTION export_schema()
RETURNS TEXT AS $$
DECLARE
    result TEXT := '';
    rec RECORD;
BEGIN
    -- Export types
    result := result || E'-- Custom Types\n';
    FOR rec IN 
        SELECT 'CREATE TYPE ' || typname || ' AS ENUM (' || 
               string_agg(quote_literal(enumlabel), ', ' ORDER BY enumsortorder) || ');' AS ddl
        FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        GROUP BY typname
    LOOP
        result := result || rec.ddl || E'\n\n';
    END LOOP;

    -- Export tables
    result := result || E'-- Tables\n';
    FOR rec IN 
        SELECT 
            'CREATE TABLE IF NOT EXISTS ' || tablename || ' (' || E'\n' ||
            string_agg(
                '  ' || column_name || ' ' || data_type || 
                CASE 
                    WHEN character_maximum_length IS NOT NULL THEN '(' || character_maximum_length || ')'
                    WHEN numeric_precision IS NOT NULL THEN '(' || numeric_precision || ',' || numeric_scale || ')'
                    ELSE ''
                END ||
                CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END ||
                CASE WHEN column_default IS NOT NULL THEN ' DEFAULT ' || column_default ELSE '' END,
                ',' || E'\n'
                ORDER BY ordinal_position
            ) || E'\n);' AS ddl
        FROM information_schema.columns
        WHERE table_schema = 'public'
        GROUP BY tablename
        ORDER BY tablename
    LOOP
        result := result || rec.ddl || E'\n\n';
    END LOOP;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Execute and get result
SELECT export_schema();

-- Clean up
DROP FUNCTION export_schema();

ROLLBACK;
```

## Best Practice: Complete Export Command

The most reliable way is to use Supabase CLI or pg_dump:

```bash
# 1. First, get your database URL from Supabase Dashboard
# Settings → Database → Connection string

# 2. Export everything (schema + RLS + functions + triggers)
pg_dump "postgresql://postgres:[YOUR-PASSWORD]@db.[YOUR-PROJECT-REF].supabase.co:5432/postgres" \
  --schema=public \
  --no-owner \
  --no-acl \
  --no-comments \
  --schema-only \
  > starnetx_complete_schema.sql

# 3. Import to new project
psql "postgresql://postgres:[NEW-PASSWORD]@db.[NEW-PROJECT-REF].supabase.co:5432/postgres" \
  < starnetx_complete_schema.sql
```

## After Export

1. Open the exported SQL file
2. Remove any lines that reference `postgres` or `supabase_admin` roles
3. Keep all the `CREATE TABLE`, `CREATE POLICY`, `CREATE FUNCTION`, etc.
4. Run the cleaned SQL in your new Supabase project

This will give you an exact copy of your database structure!