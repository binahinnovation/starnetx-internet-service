# 🚀 StarNetX Supabase Migration Guide

## Overview
This guide will help you migrate your StarNetX database schema, RLS policies, and functions to a new Supabase account.

## Prerequisites
- A new Supabase account/project
- Access to the Supabase Dashboard
- The `MASTER_MIGRATION_COMPLETE.sql` file

## 📋 Step-by-Step Migration Process

### Step 1: Create a New Supabase Project
1. Go to [Supabase Dashboard](https://app.supabase.com)
2. Click **"New Project"**
3. Fill in the project details:
   - **Name**: Your project name (e.g., "StarNetX")
   - **Database Password**: Choose a strong password (save this!)
   - **Region**: Select the closest region to your users
4. Click **"Create new project"** and wait for it to be ready

### Step 2: Configure Authentication
1. In your Supabase Dashboard, go to **Authentication** → **Providers**
2. Enable **Email** authentication
3. Configure email settings:
   - Enable email confirmations if needed
   - Set up email templates

### Step 3: Run the Master Migration Script

#### Option A: Using SQL Editor (Recommended)
1. In your Supabase Dashboard, go to **SQL Editor**
2. Click **"New query"**
3. Copy the entire contents of `MASTER_MIGRATION_COMPLETE.sql`
4. Paste it into the SQL Editor
5. Click **"Run"** (or press `Ctrl+Enter` / `Cmd+Enter`)
6. Wait for the script to complete (you should see success messages)

#### Option B: Using Multiple Smaller Scripts
If the master script is too large, you can run it in parts:

1. **Part 1**: Tables and Types
   - Run lines 1-130 (Custom types and table creation)
   
2. **Part 2**: Indexes
   - Run lines 131-150 (All indexes)
   
3. **Part 3**: RLS and Functions
   - Run lines 151-400 (Enable RLS and create functions)
   
4. **Part 4**: Triggers and Policies
   - Run lines 401-end (Triggers and RLS policies)

### Step 4: Verify the Migration

Run these verification queries in the SQL Editor:

```sql
-- Check if all tables were created
SELECT table_name FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;

-- Expected tables:
-- admin_notifications
-- credential_pools
-- locations
-- plans
-- profiles
-- transactions

-- Check if RLS is enabled
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' 
AND rowsecurity = true;

-- Check if policies were created
SELECT COUNT(*) as policy_count 
FROM pg_policies 
WHERE schemaname = 'public';
-- Should return 20+ policies

-- Check if functions were created
SELECT routine_name 
FROM information_schema.routines 
WHERE routine_schema = 'public' 
AND routine_type = 'FUNCTION';
```

### Step 5: Configure Your Application

1. **Get your Supabase credentials**:
   - Go to **Settings** → **API**
   - Copy your:
     - `Project URL` (looks like: https://xxxxx.supabase.co)
     - `Anon/Public Key` (for client-side)
     - `Service Role Key` (for server-side, keep secret!)

2. **Update your application's environment variables**:
   ```env
   VITE_SUPABASE_URL=your_project_url
   VITE_SUPABASE_ANON_KEY=your_anon_key
   ```

3. **For server-side operations** (if applicable):
   ```env
   SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
   ```

### Step 6: Test the Migration

1. **Create a test user**:
   - Use your app's signup flow
   - Or create via Supabase Dashboard → Authentication → Users

2. **Verify profile creation**:
   ```sql
   SELECT * FROM profiles;
   -- Should show the new user with a referral code
   ```

3. **Test RLS policies**:
   - Try accessing data as the test user
   - Verify users can only see their own data

### Step 7: Migrate Existing Data (Optional)

If you have existing data to migrate:

1. **Export data from old project**:
   ```sql
   -- In old project's SQL Editor
   SELECT * FROM profiles;
   SELECT * FROM plans;
   SELECT * FROM locations;
   SELECT * FROM transactions;
   SELECT * FROM credential_pools;
   ```

2. **Import to new project**:
   - Use Supabase's CSV import feature
   - Or create INSERT statements

### Step 8: Set Up Webhooks (If Using Payment Integration)

1. Go to **Database** → **Webhooks**
2. Create webhooks for:
   - Transaction creation
   - Wallet top-ups
   - Payment confirmations

### Step 9: Configure Storage (Optional)

If your app uses file storage:
1. Go to **Storage**
2. Create buckets as needed
3. Set up storage policies

## 🔧 Troubleshooting

### Common Issues and Solutions

#### Issue: "permission denied for schema public"
**Solution**: Make sure you're running the script as the database owner. Try running this first:
```sql
GRANT ALL ON SCHEMA public TO postgres;
GRANT CREATE ON SCHEMA public TO postgres;
```

#### Issue: "type app_role already exists"
**Solution**: The migration was partially run before. Drop existing objects:
```sql
DROP TYPE IF EXISTS app_role CASCADE;
-- Then run the migration again
```

#### Issue: "relation auth.users does not exist"
**Solution**: Make sure authentication is enabled in your Supabase project before running the migration.

#### Issue: RLS policies blocking access
**Solution**: Check if the user has the correct role:
```sql
-- Check user's role
SELECT * FROM profiles WHERE id = 'user_uuid_here';

-- Temporarily disable RLS for debugging (DON'T DO IN PRODUCTION)
ALTER TABLE table_name DISABLE ROW LEVEL SECURITY;
```

## 📝 Post-Migration Checklist

- [ ] All tables created successfully
- [ ] RLS is enabled on all tables
- [ ] All policies are in place
- [ ] Functions and triggers are working
- [ ] Test user can sign up and get a profile
- [ ] Test user can only see their own data
- [ ] Admin user can see all data
- [ ] Payment webhooks configured (if applicable)
- [ ] Environment variables updated in application
- [ ] Application connects successfully to new database

## 🔐 Security Best Practices

1. **Never expose your Service Role Key** in client-side code
2. **Always use RLS** for data protection
3. **Regularly backup your database**
4. **Monitor database usage** in Supabase Dashboard
5. **Set up alerts** for unusual activity

## 📚 Additional Resources

- [Supabase Documentation](https://supabase.com/docs)
- [RLS Guide](https://supabase.com/docs/guides/auth/row-level-security)
- [Database Functions](https://supabase.com/docs/guides/database/functions)
- [Webhooks Guide](https://supabase.com/docs/guides/database/webhooks)

## 💡 Tips

1. **Test in a development project first** before migrating production data
2. **Keep the master migration file** for future reference
3. **Document any custom modifications** you make
4. **Use version control** for your migration scripts
5. **Schedule migrations during low-traffic periods**

## 🆘 Need Help?

If you encounter issues:
1. Check the Supabase system status
2. Review the SQL Editor output for specific error messages
3. Consult the Supabase Discord community
4. Check the project logs in Dashboard → Logs → Postgres

---

**Migration Script Location**: `/workspace/MASTER_MIGRATION_COMPLETE.sql`

**Last Updated**: January 2025

Good luck with your migration! 🎉