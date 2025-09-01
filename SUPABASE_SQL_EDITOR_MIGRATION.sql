-- ============================================
-- STARNETX DATABASE SETUP - SQL EDITOR VERSION
-- Run this directly in Supabase SQL Editor
-- ============================================

-- ============================================
-- STEP 1: CREATE CUSTOM TYPES
-- ============================================

-- Create app_role enum type (skip if exists)
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role') THEN
    CREATE TYPE app_role AS ENUM ('admin', 'user');
  END IF;
END $$;

-- ============================================
-- STEP 2: CREATE TABLES
-- ============================================

-- 1. Profiles table
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT UNIQUE NOT NULL,
  phone TEXT,
  first_name TEXT,
  last_name TEXT,
  bvn TEXT,
  wallet_balance NUMERIC(10,2) DEFAULT 0,
  referral_code TEXT UNIQUE,
  referred_by UUID REFERENCES profiles(id),
  role app_role DEFAULT 'user',
  virtual_account_number TEXT,
  virtual_account_bank_name TEXT,
  virtual_account_reference TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Plans table
CREATE TABLE IF NOT EXISTS public.plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  duration_hours INTEGER NOT NULL,
  price NUMERIC(10,2) NOT NULL,
  duration TEXT,
  data_amount TEXT,
  type TEXT DEFAULT '3-hour' CHECK (type IN ('3-hour', 'daily', 'weekly', 'monthly')),
  popular BOOLEAN DEFAULT false,
  is_unlimited BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Locations table
CREATE TABLE IF NOT EXISTS public.locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  wifi_name TEXT NOT NULL,
  username TEXT,
  password TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Credential pools table
CREATE TABLE IF NOT EXISTS public.credential_pools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id UUID NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  username TEXT NOT NULL,
  password TEXT NOT NULL,
  status TEXT DEFAULT 'available' CHECK (status IN ('available', 'used', 'disabled')),
  assigned_to UUID REFERENCES profiles(id),
  assigned_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(location_id, plan_id, username)
);

-- 5. Transactions table
CREATE TABLE IF NOT EXISTS public.transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  plan_id UUID REFERENCES plans(id),
  location_id UUID REFERENCES locations(id),
  credential_id UUID REFERENCES credential_pools(id),
  amount NUMERIC(10,2) NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('wallet_topup', 'plan_purchase', 'wallet_funding')),
  status TEXT DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'failed', 'success')),
  mikrotik_username TEXT,
  mikrotik_password TEXT,
  expires_at TIMESTAMPTZ,
  purchase_date TIMESTAMPTZ DEFAULT NOW(),
  activation_date TIMESTAMPTZ,
  flutterwave_reference TEXT,
  flutterwave_tx_ref TEXT,
  payment_method TEXT,
  metadata JSONB,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  reference TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 6. Admin notifications table
CREATE TABLE IF NOT EXISTS public.admin_notifications (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  type TEXT DEFAULT 'info' CHECK (type IN ('info', 'warning', 'success', 'error')),
  priority INTEGER DEFAULT 0,
  target_audience TEXT DEFAULT 'all' CHECK (target_audience IN ('all', 'users', 'admins')),
  start_date TIMESTAMPTZ,
  end_date TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 3: CREATE INDEXES
-- ============================================

CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at);
CREATE INDEX IF NOT EXISTS idx_transactions_flw_tx_ref ON transactions(flutterwave_tx_ref);
CREATE INDEX IF NOT EXISTS idx_transactions_details ON transactions USING GIN (details);
CREATE INDEX IF NOT EXISTS idx_transactions_reference ON transactions(reference);
CREATE INDEX IF NOT EXISTS idx_credential_pools_status ON credential_pools(status);
CREATE INDEX IF NOT EXISTS idx_credential_pools_location_plan ON credential_pools(location_id, plan_id);
CREATE INDEX IF NOT EXISTS idx_admin_notifications_active ON admin_notifications(is_active);
CREATE INDEX IF NOT EXISTS idx_admin_notifications_dates ON admin_notifications(start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_admin_notifications_target ON admin_notifications(target_audience);

-- ============================================
-- STEP 4: ENABLE ROW LEVEL SECURITY
-- ============================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE credential_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications ENABLE ROW LEVEL SECURITY;

-- ============================================
-- STEP 5: CREATE HELPER FUNCTIONS
-- ============================================

-- Get user role function
CREATE OR REPLACE FUNCTION get_user_role(user_id UUID)
RETURNS app_role 
LANGUAGE plpgsql 
SECURITY DEFINER
AS $$
BEGIN
  RETURN (SELECT role FROM profiles WHERE id = user_id);
END;
$$;

-- Check if current user is admin
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN 
LANGUAGE plpgsql 
SECURITY DEFINER
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role = 'admin'
  );
END;
$$;

-- Handle new user registration
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER 
LANGUAGE plpgsql 
SECURITY DEFINER
AS $$
BEGIN
  -- Check if profile already exists
  IF EXISTS (SELECT 1 FROM profiles WHERE id = NEW.id) THEN
    RETURN NEW;
  END IF;
  
  -- Create profile with referral code
  INSERT INTO profiles (id, email, referral_code)
  VALUES (
    NEW.id,
    NEW.email,
    UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6))
  )
  ON CONFLICT (id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- Update timestamp function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER 
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Validate referral code
CREATE OR REPLACE FUNCTION validate_referral_code(code TEXT)
RETURNS BOOLEAN 
LANGUAGE plpgsql 
SECURITY DEFINER
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE referral_code = UPPER(code)
    AND id != auth.uid()
  );
END;
$$;

-- Check if referral code exists
CREATE OR REPLACE FUNCTION check_referral_code_exists(code TEXT)
RETURNS BOOLEAN 
LANGUAGE plpgsql 
SECURITY DEFINER
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE referral_code = UPPER(code)
  );
END;
$$;

-- ============================================
-- STEP 6: CREATE TRIGGERS
-- ============================================

-- Auto-create profile on user signup
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW 
  EXECUTE FUNCTION handle_new_user();

-- Auto-update timestamps
DROP TRIGGER IF EXISTS update_profiles_updated_at ON profiles;
CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_plans_updated_at ON plans;
CREATE TRIGGER update_plans_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_locations_updated_at ON locations;
CREATE TRIGGER update_locations_updated_at
  BEFORE UPDATE ON locations
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_credential_pools_updated_at ON credential_pools;
CREATE TRIGGER update_credential_pools_updated_at
  BEFORE UPDATE ON credential_pools
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_transactions_updated_at ON transactions;
CREATE TRIGGER update_transactions_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_admin_notifications_updated_at ON admin_notifications;
CREATE TRIGGER update_admin_notifications_updated_at
  BEFORE UPDATE ON admin_notifications
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- STEP 7: CREATE RLS POLICIES
-- ============================================

-- PROFILES POLICIES
DROP POLICY IF EXISTS "Users can view own profile" ON profiles;
CREATE POLICY "Users can view own profile" 
  ON profiles FOR SELECT 
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
CREATE POLICY "Users can update own profile" 
  ON profiles FOR UPDATE 
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can insert own profile" ON profiles;
CREATE POLICY "Users can insert own profile" 
  ON profiles FOR INSERT 
  WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Admins can view all profiles" ON profiles;
CREATE POLICY "Admins can view all profiles" 
  ON profiles FOR SELECT 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

DROP POLICY IF EXISTS "Admins can manage all profiles" ON profiles;
CREATE POLICY "Admins can manage all profiles" 
  ON profiles FOR ALL 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

-- PLANS POLICIES
DROP POLICY IF EXISTS "Anyone can view active plans" ON plans;
CREATE POLICY "Anyone can view active plans" 
  ON plans FOR SELECT 
  USING (is_active = true);

DROP POLICY IF EXISTS "Admins can manage plans" ON plans;
CREATE POLICY "Admins can manage plans" 
  ON plans FOR ALL 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

-- LOCATIONS POLICIES
DROP POLICY IF EXISTS "Anyone can view active locations" ON locations;
CREATE POLICY "Anyone can view active locations" 
  ON locations FOR SELECT 
  USING (is_active = true);

DROP POLICY IF EXISTS "Admins can manage locations" ON locations;
CREATE POLICY "Admins can manage locations" 
  ON locations FOR ALL 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

-- CREDENTIAL_POOLS POLICIES
DROP POLICY IF EXISTS "Users can view assigned credentials" ON credential_pools;
CREATE POLICY "Users can view assigned credentials" 
  ON credential_pools FOR SELECT 
  USING (assigned_to = auth.uid());

DROP POLICY IF EXISTS "Users can view available credentials" ON credential_pools;
CREATE POLICY "Users can view available credentials" 
  ON credential_pools FOR SELECT 
  USING (status = 'available');

DROP POLICY IF EXISTS "Admins can manage credentials" ON credential_pools;
CREATE POLICY "Admins can manage credentials" 
  ON credential_pools FOR ALL 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

-- TRANSACTIONS POLICIES
DROP POLICY IF EXISTS "Users can view own transactions" ON transactions;
CREATE POLICY "Users can view own transactions" 
  ON transactions FOR SELECT 
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can create own transactions" ON transactions;
CREATE POLICY "Users can create own transactions" 
  ON transactions FOR INSERT 
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can update own transactions" ON transactions;
CREATE POLICY "Users can update own transactions" 
  ON transactions FOR UPDATE 
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can manage all transactions" ON transactions;
CREATE POLICY "Admins can manage all transactions" 
  ON transactions FOR ALL 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

-- ADMIN_NOTIFICATIONS POLICIES
DROP POLICY IF EXISTS "Anyone can view active notifications" ON admin_notifications;
CREATE POLICY "Anyone can view active notifications" 
  ON admin_notifications FOR SELECT 
  USING (
    is_active = true 
    AND (start_date IS NULL OR start_date <= NOW())
    AND (end_date IS NULL OR end_date >= NOW())
    AND (
      target_audience = 'all' 
      OR (target_audience = 'users' AND EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'user'
      ))
      OR (target_audience = 'admins' AND EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
      ))
    )
  );

DROP POLICY IF EXISTS "Admins can manage notifications" ON admin_notifications;
CREATE POLICY "Admins can manage notifications" 
  ON admin_notifications FOR ALL 
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE id = auth.uid() 
      AND role = 'admin'
    )
  );

-- ============================================
-- STEP 8: GRANT PERMISSIONS
-- ============================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

-- ============================================
-- STEP 9: INSERT SAMPLE DATA (OPTIONAL)
-- ============================================

-- Uncomment to add sample data

/*
-- Sample plans
INSERT INTO plans (name, duration_hours, price, duration, data_amount, type, popular, is_unlimited, is_active) 
VALUES
  ('3 Hours Unlimited', 3, 100, '3 Hours', 'Unlimited', '3-hour', false, true, true),
  ('Daily Unlimited', 24, 300, '1 Day', 'Unlimited', 'daily', true, true, true),
  ('Weekly Unlimited', 168, 1500, '1 Week', 'Unlimited', 'weekly', false, true, true),
  ('Monthly Unlimited', 720, 5000, '1 Month', 'Unlimited', 'monthly', false, true, true)
ON CONFLICT DO NOTHING;

-- Sample locations
INSERT INTO locations (name, wifi_name, username, password, is_active) 
VALUES
  ('Main Campus', 'StarNetX_Main', 'admin', 'password123', true),
  ('Library', 'StarNetX_Library', 'admin', 'password123', true),
  ('Cafeteria', 'StarNetX_Cafe', 'admin', 'password123', true)
ON CONFLICT DO NOTHING;
*/

-- ============================================
-- STEP 10: VERIFY SETUP
-- ============================================

-- Check tables
SELECT table_name, 
       CASE WHEN rowsecurity THEN '✅ RLS Enabled' ELSE '❌ RLS Disabled' END as rls_status
FROM pg_tables 
WHERE schemaname = 'public'
ORDER BY table_name;

-- Check policies count
SELECT tablename, COUNT(*) as policy_count 
FROM pg_policies 
WHERE schemaname = 'public'
GROUP BY tablename
ORDER BY tablename;

-- Check functions
SELECT routine_name 
FROM information_schema.routines 
WHERE routine_schema = 'public' 
AND routine_type = 'FUNCTION'
ORDER BY routine_name;

-- ============================================
-- SUCCESS MESSAGE
-- ============================================
DO $$
BEGIN
  RAISE NOTICE '✅ Database setup completed successfully!';
  RAISE NOTICE '📊 Tables created: profiles, plans, locations, credential_pools, transactions, admin_notifications';
  RAISE NOTICE '🔒 RLS enabled on all tables';
  RAISE NOTICE '📋 Policies created for all tables';
  RAISE NOTICE '⚡ Functions and triggers active';
END $$;