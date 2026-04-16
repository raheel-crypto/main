-- RLS Policies for Sales Pipeline Review App

-- Helper function to get user's ID from auth
CREATE OR REPLACE FUNCTION get_current_user_id()
RETURNS UUID AS $$
  SELECT id FROM users WHERE auth_id = auth.uid()
$$ LANGUAGE sql SECURITY DEFINER;

-- Helper function to check if current user is a manager of a rep
CREATE OR REPLACE FUNCTION is_manager_of(rep_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM users 
    WHERE id = rep_user_id 
    AND manager_id = get_current_user_id()
  )
$$ LANGUAGE sql SECURITY DEFINER;

-- Helper function to check if user is admin
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM users 
    WHERE auth_id = auth.uid() 
    AND role = 'admin'
  )
$$ LANGUAGE sql SECURITY DEFINER;

-- Users policies
CREATE POLICY "users_select_own_and_reports" ON users
  FOR SELECT USING (
    auth_id = auth.uid() 
    OR manager_id = get_current_user_id()
    OR is_admin()
  );

CREATE POLICY "users_insert_own" ON users
  FOR INSERT WITH CHECK (auth_id = auth.uid());

CREATE POLICY "users_update_own" ON users
  FOR UPDATE USING (auth_id = auth.uid());

-- Accounts policies (all authenticated users can see accounts)
CREATE POLICY "accounts_select_all" ON accounts
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "accounts_insert_auth" ON accounts
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "accounts_update_auth" ON accounts
  FOR UPDATE USING (auth.uid() IS NOT NULL);

-- Deals policies
CREATE POLICY "deals_select_own_and_managed" ON deals
  FOR SELECT USING (
    owner_id = get_current_user_id()
    OR is_manager_of(owner_id)
    OR is_admin()
  );

CREATE POLICY "deals_insert_own" ON deals
  FOR INSERT WITH CHECK (owner_id = get_current_user_id() OR is_admin());

CREATE POLICY "deals_update_own" ON deals
  FOR UPDATE USING (owner_id = get_current_user_id() OR is_admin());

-- Review weeks policies
CREATE POLICY "review_weeks_select_own_and_managed" ON review_weeks
  FOR SELECT USING (
    rep_id = get_current_user_id()
    OR is_manager_of(rep_id)
    OR is_admin()
  );

CREATE POLICY "review_weeks_insert_own" ON review_weeks
  FOR INSERT WITH CHECK (rep_id = get_current_user_id());

CREATE POLICY "review_weeks_update_own_and_manager" ON review_weeks
  FOR UPDATE USING (
    rep_id = get_current_user_id()
    OR is_manager_of(rep_id)
  );

-- Weekly focus accounts policies
CREATE POLICY "focus_accounts_select" ON weekly_focus_accounts
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND (rw.rep_id = get_current_user_id() OR is_manager_of(rw.rep_id) OR is_admin())
    )
  );

CREATE POLICY "focus_accounts_insert" ON weekly_focus_accounts
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND rw.rep_id = get_current_user_id()
    )
  );

CREATE POLICY "focus_accounts_update" ON weekly_focus_accounts
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND rw.rep_id = get_current_user_id()
    )
  );

CREATE POLICY "focus_accounts_delete" ON weekly_focus_accounts
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND rw.rep_id = get_current_user_id()
    )
  );

-- Weekly commitments policies
CREATE POLICY "commitments_select" ON weekly_commitments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND (rw.rep_id = get_current_user_id() OR is_manager_of(rw.rep_id) OR is_admin())
    )
  );

CREATE POLICY "commitments_insert" ON weekly_commitments
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND rw.rep_id = get_current_user_id()
    )
  );

CREATE POLICY "commitments_update" ON weekly_commitments
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND (rw.rep_id = get_current_user_id() OR is_manager_of(rw.rep_id))
    )
  );

CREATE POLICY "commitments_delete" ON weekly_commitments
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND rw.rep_id = get_current_user_id()
    )
  );

-- Activities policies
CREATE POLICY "activities_select_own_and_managed" ON activities
  FOR SELECT USING (
    rep_id = get_current_user_id()
    OR is_manager_of(rep_id)
    OR is_admin()
  );

CREATE POLICY "activities_insert" ON activities
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Integrations policies
CREATE POLICY "integrations_select_own" ON integrations
  FOR SELECT USING (user_id = get_current_user_id() OR is_admin());

CREATE POLICY "integrations_insert_own" ON integrations
  FOR INSERT WITH CHECK (user_id = get_current_user_id());

CREATE POLICY "integrations_update_own" ON integrations
  FOR UPDATE USING (user_id = get_current_user_id());

-- Review comments policies
CREATE POLICY "comments_select" ON review_comments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND (rw.rep_id = get_current_user_id() OR is_manager_of(rw.rep_id) OR is_admin())
    )
  );

CREATE POLICY "comments_insert" ON review_comments
  FOR INSERT WITH CHECK (
    user_id = get_current_user_id()
    AND EXISTS (
      SELECT 1 FROM review_weeks rw
      WHERE rw.id = review_week_id
      AND (rw.rep_id = get_current_user_id() OR is_manager_of(rw.rep_id))
    )
  );
