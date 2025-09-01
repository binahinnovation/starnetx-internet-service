-- ============================================
-- Complete StarNetX Schema Migration
-- Single file containing all database objects
-- ============================================

-- Create custom types
DO $$ BEGIN
  CREATE TYPE app_role AS ENUM ('admin', 'user');
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

-- Create all tables
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

CREATE TABLE IF NOT EXISTS plans (
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

CREATE TABLE IF NOT EXISTS transactions (
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

-- Create indexes
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

-- Enable RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE credential_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications ENABLE ROW LEVEL SECURITY;

-- Create functions
CREATE OR REPLACE FUNCTION get_user_role(user_id UUID)
RETURNS app_role AS $$
BEGIN
  RETURN (SELECT role FROM profiles WHERE id = user_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION uid() RETURNS UUID AS $$
  SELECT auth.uid();
$$ LANGUAGE sql STABLE;

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

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
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

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_referral_code(code TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE referral_code = UPPER(code)
    AND id != auth.uid()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION check_referral_code_exists(code TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM profiles WHERE referral_code = UPPER(code));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
  BEGIN
    SELECT wallet_balance INTO v_user_balance
    FROM profiles
    WHERE id = p_user_id
    FOR UPDATE;
    
    IF v_user_balance IS NULL THEN
      RAISE EXCEPTION 'User not found';
    END IF;
    
    IF v_user_balance < p_amount THEN
      RAISE EXCEPTION 'Insufficient balance. Required: %, Available: %', p_amount, v_user_balance;
    END IF;
    
    SELECT status INTO v_credential_status
    FROM credential_pools
    WHERE id = p_credential_id
    FOR UPDATE;
    
    IF v_credential_status != 'available' THEN
      RAISE EXCEPTION 'Credential not available. Status: %', v_credential_status;
    END IF;
    
    UPDATE profiles
    SET wallet_balance = wallet_balance - p_amount
    WHERE id = p_user_id;
    
    UPDATE credential_pools
    SET 
      status = 'used',
      assigned_to = p_user_id,
      assigned_at = NOW(),
      updated_at = NOW()
    WHERE id = p_credential_id;
    
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
      RAISE EXCEPTION 'Purchase failed: %', SQLERRM;
  END;
END;
$$;

-- Create triggers
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_plans_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_locations_updated_at
  BEFORE UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_credential_pools_updated_at
  BEFORE UPDATE ON credential_pools
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_transactions_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_admin_notifications_updated_at
  BEFORE UPDATE ON admin_notifications
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Create RLS policies
CREATE POLICY "Users can view own profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile" ON profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Admins can view all profiles" ON profiles FOR SELECT USING (get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Anyone can check referral codes" ON profiles FOR SELECT USING (true) WITH CHECK (false);
CREATE POLICY "Users can view referred users" ON profiles FOR SELECT USING (referred_by = auth.uid());

CREATE POLICY "Anyone can view active plans" ON plans FOR SELECT USING (is_active = true);
CREATE POLICY "Admins can manage plans" ON plans FOR ALL USING (get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Anyone can view active locations" ON locations FOR SELECT USING (is_active = true);
CREATE POLICY "Admins can manage locations" ON locations FOR ALL USING (get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Users can view their assigned credentials" ON credential_pools FOR SELECT USING (assigned_to = auth.uid());
CREATE POLICY "Users can view available credentials for purchase" ON credential_pools FOR SELECT USING (status = 'available');
CREATE POLICY "Users can assign available credentials to themselves" ON credential_pools FOR UPDATE USING (status = 'available') WITH CHECK (assigned_to = auth.uid() AND status = 'used');
CREATE POLICY "Admins can manage credentials" ON credential_pools FOR ALL USING (get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Users can view own transactions" ON transactions FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users can create own transactions" ON transactions FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Users can update own transactions" ON transactions FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "Admins can view all transactions" ON transactions FOR ALL USING (get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Users can view transactions of referred users" ON transactions FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = transactions.user_id AND profiles.referred_by = auth.uid()));

CREATE POLICY "Anyone can view active notifications" ON admin_notifications FOR SELECT 
USING (
  is_active = true 
  AND (
    target_audience = 'all' 
    OR (target_audience = 'users' AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'user'))
    OR (target_audience = 'admins' AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'))
  )
  AND (start_date IS NULL OR start_date <= NOW())
  AND (end_date IS NULL OR end_date >= NOW())
);
CREATE POLICY "Admins can manage all notifications" ON admin_notifications FOR ALL USING (get_user_role(auth.uid()) = 'admin');

-- Grant permissions
GRANT EXECUTE ON FUNCTION purchase_plan_transaction(UUID, UUID, UUID, UUID, DECIMAL, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION validate_referral_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION check_referral_code_exists(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_role(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION is_admin() TO authenticated;