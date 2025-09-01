-- ============================================
-- STARNETX COMPLETE DATABASE MIGRATION SCRIPT
-- ============================================
-- This is a comprehensive migration file that includes:
-- 1. All tables with complete schema
-- 2. All RLS (Row Level Security) policies  
-- 3. All functions and triggers
-- 4. All indexes and constraints
-- 
-- Instructions:
-- 1. Create a new Supabase project
-- 2. Go to SQL Editor in your Supabase dashboard
-- 3. Copy and paste this entire script
-- 4. Click "Run" to execute
-- ============================================

-- ============================================
-- PART 1: CREATE CUSTOM TYPES
-- ============================================

-- Drop existing types if they exist (for re-running)
DROP TYPE IF EXISTS app_role CASCADE;

-- Create custom types
CREATE TYPE app_role AS ENUM ('admin', 'user');

-- ============================================
-- PART 2: CREATE ALL TABLES
-- ============================================

-- 1. PROFILES TABLE
CREATE TABLE IF NOT EXISTS profiles (
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

-- 2. PLANS TABLE
CREATE TABLE IF NOT EXISTS plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  duration_hours INTEGER NOT NULL,
  price NUMERIC(10,2) NOT NULL,
  duration TEXT,
  data_amount TEXT,
  type TEXT DEFAULT '3-hour',
  popular BOOLEAN DEFAULT false,
  is_unlimited BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT plans_type_check CHECK (type IN ('3-hour', 'daily', 'weekly', 'monthly'))
);

-- 3. LOCATIONS TABLE
CREATE TABLE IF NOT EXISTS locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  wifi_name TEXT NOT NULL,
  username TEXT,
  password TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. CREDENTIAL_POOLS TABLE
CREATE TABLE IF NOT EXISTS credential_pools (
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

-- 5. TRANSACTIONS TABLE
CREATE TABLE IF NOT EXISTS transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  plan_id UUID REFERENCES plans(id),
  location_id UUID REFERENCES locations(id),
  credential_id UUID REFERENCES credential_pools(id),
  amount NUMERIC(10,2) NOT NULL,
  type TEXT NOT NULL,
  status TEXT DEFAULT 'completed',
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
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT transactions_type_check CHECK (type IN ('wallet_topup', 'plan_purchase', 'wallet_funding')),
  CONSTRAINT transactions_status_check CHECK (status IN ('pending', 'completed', 'failed', 'success'))
);

-- 6. ADMIN_NOTIFICATIONS TABLE
CREATE TABLE IF NOT EXISTS admin_notifications (
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
-- PART 3: CREATE INDEXES FOR PERFORMANCE
-- ============================================

-- Transactions indexes
CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at);
CREATE INDEX IF NOT EXISTS idx_transactions_flw_tx_ref ON transactions(flutterwave_tx_ref);
CREATE INDEX IF NOT EXISTS idx_transactions_details ON transactions USING GIN (details);
CREATE INDEX IF NOT EXISTS idx_transactions_reference ON transactions(reference);

-- Credential pools indexes
CREATE INDEX IF NOT EXISTS idx_credential_pools_status ON credential_pools(status);
CREATE INDEX IF NOT EXISTS idx_credential_pools_location_plan ON credential_pools(location_id, plan_id);

-- Admin notifications indexes
CREATE INDEX IF NOT EXISTS idx_admin_notifications_active ON admin_notifications(is_active);
CREATE INDEX IF NOT EXISTS idx_admin_notifications_dates ON admin_notifications(start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_admin_notifications_target ON admin_notifications(target_audience);

-- ============================================
-- PART 4: ENABLE ROW LEVEL SECURITY
-- ============================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE credential_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications ENABLE ROW LEVEL SECURITY;

-- ============================================
-- PART 5: CREATE FUNCTIONS
-- ============================================

-- Function to get user role
CREATE OR REPLACE FUNCTION get_user_role(user_id UUID)
RETURNS app_role AS $$
BEGIN
  RETURN (SELECT role FROM profiles WHERE id = user_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get current user ID
CREATE OR REPLACE FUNCTION uid() RETURNS UUID AS $$
  SELECT auth.uid();
$$ LANGUAGE sql STABLE;

-- Function to check if user is admin
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role = 'admin'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to handle new user registration
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Check if profile already exists
  IF EXISTS (SELECT 1 FROM profiles WHERE id = NEW.id) THEN
    RETURN NEW;
  END IF;
  
  INSERT INTO profiles (id, email, referral_code)
  VALUES (
    NEW.id,
    NEW.email,
    UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to validate referral code
CREATE OR REPLACE FUNCTION validate_referral_code(code TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  -- Check if the referral code exists and belongs to a different user
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE referral_code = UPPER(code)
    AND id != auth.uid()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check referral code exists
CREATE OR REPLACE FUNCTION check_referral_code_exists(code TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM profiles WHERE referral_code = UPPER(code));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to handle plan purchases atomically
CREATE OR REPLACE FUNCTION purchase_plan_transaction(
  p_user_id UUID,
  p_plan_id UUID,
  p_location_id UUID,
  p_credential_id UUID,
  p_amount DECIMAL(10,2),
  p_duration_hours INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_balance DECIMAL(10,2);
  v_credential_status TEXT;
  v_transaction_id UUID;
  v_result JSONB;
BEGIN
  -- Start transaction
  BEGIN
    -- Lock the user profile row to prevent concurrent balance updates
    SELECT wallet_balance INTO v_user_balance
    FROM profiles
    WHERE id = p_user_id
    FOR UPDATE;
    
    -- Check if user exists and has sufficient balance
    IF v_user_balance IS NULL THEN
      RAISE EXCEPTION 'User not found';
    END IF;
    
    IF v_user_balance < p_amount THEN
      RAISE EXCEPTION 'Insufficient balance. Required: %, Available: %', p_amount, v_user_balance;
    END IF;
    
    -- Lock the credential row to prevent concurrent assignment
    SELECT status INTO v_credential_status
    FROM credential_pools
    WHERE id = p_credential_id
    FOR UPDATE;
    
    -- Check if credential is available
    IF v_credential_status != 'available' THEN
      RAISE EXCEPTION 'Credential not available. Status: %', v_credential_status;
    END IF;
    
    -- Deduct amount from user wallet
    UPDATE profiles
    SET wallet_balance = wallet_balance - p_amount
    WHERE id = p_user_id;
    
    -- Mark credential as used
    UPDATE credential_pools
    SET 
      status = 'used',
      assigned_to = p_user_id,
      assigned_at = NOW(),
      updated_at = NOW()
    WHERE id = p_credential_id;
    
    -- Create transaction record
    INSERT INTO transactions (
      user_id,
      plan_id,
      location_id,
      credential_id,
      amount,
      type,
      status,
      mikrotik_username,
      mikrotik_password,
      purchase_date,
      expires_at
    ) VALUES (
      p_user_id,
      p_plan_id,
      p_location_id,
      p_credential_id,
      p_amount,
      'plan_purchase',
      'completed',
      (SELECT username FROM credential_pools WHERE id = p_credential_id),
      (SELECT password FROM credential_pools WHERE id = p_credential_id),
      NOW(),
      NOW() + INTERVAL '1 hour' * p_duration_hours
    ) RETURNING id INTO v_transaction_id;
    
    -- Return success result
    v_result := jsonb_build_object(
      'success', true,
      'transaction_id', v_transaction_id,
      'user_id', p_user_id,
      'plan_id', p_plan_id,
      'location_id', p_location_id,
      'credential_id', p_credential_id,
      'amount', p_amount,
      'expires_at', NOW() + INTERVAL '1 hour' * p_duration_hours
    );
    
    RETURN v_result;
    
  EXCEPTION
    WHEN OTHERS THEN
      -- Rollback will happen automatically
      RAISE EXCEPTION 'Purchase failed: %', SQLERRM;
  END;
END;
$$;

-- ============================================
-- PART 6: CREATE TRIGGERS
-- ============================================

-- Trigger for new user registration
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- Triggers for updated_at columns
DROP TRIGGER IF EXISTS update_profiles_updated_at ON profiles;
CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_plans_updated_at ON plans;
CREATE TRIGGER update_plans_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_locations_updated_at ON locations;
CREATE TRIGGER update_locations_updated_at
  BEFORE UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_credential_pools_updated_at ON credential_pools;
CREATE TRIGGER update_credential_pools_updated_at
  BEFORE UPDATE ON credential_pools
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_transactions_updated_at ON transactions;
CREATE TRIGGER update_transactions_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_admin_notifications_updated_at ON admin_notifications;
CREATE TRIGGER update_admin_notifications_updated_at
  BEFORE UPDATE ON admin_notifications
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- PART 7: CREATE RLS POLICIES
-- ============================================

-- PROFILES TABLE POLICIES
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
USING (get_user_role(auth.uid()) = 'admin');

DROP POLICY IF EXISTS "Anyone can check referral codes" ON profiles;
CREATE POLICY "Anyone can check referral codes" 
ON profiles FOR SELECT 
USING (true);

DROP POLICY IF EXISTS "Users can view referred users" ON profiles;
CREATE POLICY "Users can view referred users" 
ON profiles FOR SELECT 
USING (
  referred_by = auth.uid()
);

-- PLANS TABLE POLICIES
DROP POLICY IF EXISTS "Anyone can view active plans" ON plans;
CREATE POLICY "Anyone can view active plans" 
ON plans FOR SELECT 
USING (is_active = true);

DROP POLICY IF EXISTS "Admins can manage plans" ON plans;
CREATE POLICY "Admins can manage plans" 
ON plans FOR ALL 
USING (get_user_role(auth.uid()) = 'admin');

-- LOCATIONS TABLE POLICIES
DROP POLICY IF EXISTS "Anyone can view active locations" ON locations;
CREATE POLICY "Anyone can view active locations" 
ON locations FOR SELECT 
USING (is_active = true);

DROP POLICY IF EXISTS "Admins can manage locations" ON locations;
CREATE POLICY "Admins can manage locations" 
ON locations FOR ALL 
USING (get_user_role(auth.uid()) = 'admin');

-- CREDENTIAL_POOLS TABLE POLICIES
DROP POLICY IF EXISTS "Users can view their assigned credentials" ON credential_pools;
CREATE POLICY "Users can view their assigned credentials" 
ON credential_pools FOR SELECT 
USING (assigned_to = auth.uid());

DROP POLICY IF EXISTS "Users can view available credentials for purchase" ON credential_pools;
CREATE POLICY "Users can view available credentials for purchase" 
ON credential_pools FOR SELECT 
USING (status = 'available');

DROP POLICY IF EXISTS "Users can assign available credentials to themselves" ON credential_pools;
CREATE POLICY "Users can assign available credentials to themselves" 
ON credential_pools FOR UPDATE 
USING (status = 'available')
WITH CHECK (assigned_to = auth.uid() AND status = 'used');

DROP POLICY IF EXISTS "Admins can manage credentials" ON credential_pools;
CREATE POLICY "Admins can manage credentials" 
ON credential_pools FOR ALL 
USING (get_user_role(auth.uid()) = 'admin');

-- TRANSACTIONS TABLE POLICIES
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

DROP POLICY IF EXISTS "Admins can view all transactions" ON transactions;
CREATE POLICY "Admins can view all transactions" 
ON transactions FOR ALL 
USING (get_user_role(auth.uid()) = 'admin');

DROP POLICY IF EXISTS "Users can view transactions of referred users" ON transactions;
CREATE POLICY "Users can view transactions of referred users" 
ON transactions FOR SELECT 
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = transactions.user_id 
    AND profiles.referred_by = auth.uid()
  )
);

-- ADMIN_NOTIFICATIONS TABLE POLICIES
DROP POLICY IF EXISTS "Anyone can view active notifications" ON admin_notifications;
CREATE POLICY "Anyone can view active notifications" 
ON admin_notifications FOR SELECT 
USING (
  is_active = true 
  AND (
    target_audience = 'all' 
    OR (
      target_audience = 'users' 
      AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'user')
    )
    OR (
      target_audience = 'admins' 
      AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    )
  )
  AND (start_date IS NULL OR start_date <= NOW())
  AND (end_date IS NULL OR end_date >= NOW())
);

DROP POLICY IF EXISTS "Admins can manage all notifications" ON admin_notifications;
CREATE POLICY "Admins can manage all notifications" 
ON admin_notifications FOR ALL 
USING (get_user_role(auth.uid()) = 'admin');

-- ============================================
-- PART 8: GRANT PERMISSIONS
-- ============================================

-- Grant execute permission on functions to authenticated users
GRANT EXECUTE ON FUNCTION purchase_plan_transaction(UUID, UUID, UUID, UUID, DECIMAL, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION validate_referral_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION check_referral_code_exists(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_role(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION is_admin() TO authenticated;

-- ============================================
-- PART 9: INSERT DEFAULT DATA (OPTIONAL)
-- ============================================

-- Uncomment the following sections if you want to insert sample data

/*
-- Insert sample plans
INSERT INTO plans (name, duration_hours, price, duration, data_amount, type, popular, is_unlimited, is_active) VALUES
  ('3 Hours Unlimited', 3, 100, '3 Hours', 'Unlimited', '3-hour', false, true, true),
  ('Daily Unlimited', 24, 300, '1 Day', 'Unlimited', 'daily', true, true, true),
  ('Weekly Unlimited', 168, 1500, '1 Week', 'Unlimited', 'weekly', false, true, true),
  ('Monthly Unlimited', 720, 5000, '1 Month', 'Unlimited', 'monthly', false, true, true);

-- Insert sample locations
INSERT INTO locations (name, wifi_name, username, password, is_active) VALUES
  ('Main Campus', 'StarNetX_Main', 'admin', 'password123', true),
  ('Library', 'StarNetX_Library', 'admin', 'password123', true),
  ('Cafeteria', 'StarNetX_Cafe', 'admin', 'password123', true);

-- Insert sample admin notification
INSERT INTO admin_notifications (title, message, type, priority, target_audience, is_active) VALUES
  ('Welcome to StarNetX!', 'Thank you for joining our network. Enjoy fast and reliable internet service.', 'success', 1, 'all', true);
*/

-- ============================================
-- PART 10: VERIFICATION QUERIES
-- ============================================

-- Verify tables were created
SELECT table_name FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;

-- Verify RLS is enabled
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' 
ORDER BY tablename;

-- Verify policies were created
SELECT tablename, policyname 
FROM pg_policies 
WHERE schemaname = 'public' 
ORDER BY tablename, policyname;

-- ============================================
-- END OF MIGRATION SCRIPT
-- ============================================
-- Migration completed successfully!
-- Your StarNetX database is now ready to use.
-- ============================================