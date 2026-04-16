-- Users table with manager hierarchy
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id UUID UNIQUE, -- References auth.users(id)
  email TEXT UNIQUE NOT NULL,
  full_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'sales_rep' CHECK (role IN ('sales_rep', 'manager', 'admin')),
  manager_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Accounts (companies being worked)
CREATE TABLE IF NOT EXISTS accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id TEXT,
  source TEXT DEFAULT 'manual',
  name TEXT NOT NULL,
  domain TEXT,
  industry TEXT,
  employee_count INT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Deals/Opportunities linked to accounts
CREATE TABLE IF NOT EXISTS deals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
  external_id TEXT,
  source TEXT DEFAULT 'manual',
  name TEXT NOT NULL,
  amount DECIMAL(12,2),
  stage TEXT DEFAULT 'prospecting',
  close_date DATE,
  owner_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Weekly review periods
CREATE TABLE IF NOT EXISTS review_weeks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rep_id UUID REFERENCES users(id) NOT NULL,
  week_start DATE NOT NULL,
  status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'submitted', 'reviewed')),
  manager_notes TEXT,
  reviewed_by UUID REFERENCES users(id),
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(rep_id, week_start)
);

-- Focus accounts for a week
CREATE TABLE IF NOT EXISTS weekly_focus_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  review_week_id UUID REFERENCES review_weeks(id) ON DELETE CASCADE,
  account_id UUID REFERENCES accounts(id),
  priority INT DEFAULT 1,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Commitments for a week
CREATE TABLE IF NOT EXISTS weekly_commitments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  review_week_id UUID REFERENCES review_weeks(id) ON DELETE CASCADE,
  commitment_type TEXT NOT NULL CHECK (commitment_type IN (
    'outbound_volume', 'deal_action', 'meeting_target', 
    'pipeline_generation', 'follow_up'
  )),
  description TEXT NOT NULL,
  target_value INT,
  target_amount DECIMAL(12,2),
  deal_id UUID REFERENCES deals(id),
  account_id UUID REFERENCES accounts(id),
  actual_value INT DEFAULT 0,
  actual_amount DECIMAL(12,2) DEFAULT 0,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'met', 'missed', 'exceeded')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Activity data synced from integrations
CREATE TABLE IF NOT EXISTS activities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id TEXT,
  source TEXT NOT NULL,
  activity_type TEXT NOT NULL,
  rep_id UUID REFERENCES users(id),
  account_id UUID REFERENCES accounts(id),
  deal_id UUID REFERENCES deals(id),
  contact_email TEXT,
  contact_name TEXT,
  direction TEXT,
  duration_seconds INT,
  occurred_at TIMESTAMPTZ NOT NULL,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Integration connections
CREATE TABLE IF NOT EXISTS integrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id),
  provider TEXT NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'connected', 'error')),
  last_sync_at TIMESTAMPTZ,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Manager comments on weekly reviews
CREATE TABLE IF NOT EXISTS review_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  review_week_id UUID REFERENCES review_weeks(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id),
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_manager ON users(manager_id);
CREATE INDEX IF NOT EXISTS idx_users_auth ON users(auth_id);
CREATE INDEX IF NOT EXISTS idx_deals_owner ON deals(owner_id);
CREATE INDEX IF NOT EXISTS idx_deals_account ON deals(account_id);
CREATE INDEX IF NOT EXISTS idx_review_weeks_rep ON review_weeks(rep_id);
CREATE INDEX IF NOT EXISTS idx_review_weeks_status ON review_weeks(status);
CREATE INDEX IF NOT EXISTS idx_weekly_commitments_review ON weekly_commitments(review_week_id);
CREATE INDEX IF NOT EXISTS idx_activities_rep ON activities(rep_id);
CREATE INDEX IF NOT EXISTS idx_activities_occurred ON activities(occurred_at);
CREATE INDEX IF NOT EXISTS idx_activities_account ON activities(account_id);

-- Enable RLS on all tables
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE deals ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_weeks ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_focus_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_commitments ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE integrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_comments ENABLE ROW LEVEL SECURITY;
