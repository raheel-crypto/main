-- Seed sample data for Sales Pipeline Review App
-- This creates realistic sample data to demonstrate the app's functionality

-- Insert sample managers
INSERT INTO users (id, email, full_name, role, manager_id) VALUES
  ('11111111-1111-1111-1111-111111111111', 'sarah.chen@example.com', 'Sarah Chen', 'manager', NULL),
  ('22222222-2222-2222-2222-222222222222', 'mike.johnson@example.com', 'Mike Johnson', 'manager', NULL)
ON CONFLICT (email) DO NOTHING;

-- Insert sample sales reps (reporting to managers)
INSERT INTO users (id, email, full_name, role, manager_id) VALUES
  ('33333333-3333-3333-3333-333333333333', 'alex.rivera@example.com', 'Alex Rivera', 'sales_rep', '11111111-1111-1111-1111-111111111111'),
  ('44444444-4444-4444-4444-444444444444', 'jordan.smith@example.com', 'Jordan Smith', 'sales_rep', '11111111-1111-1111-1111-111111111111'),
  ('55555555-5555-5555-5555-555555555555', 'casey.williams@example.com', 'Casey Williams', 'sales_rep', '22222222-2222-2222-2222-222222222222'),
  ('66666666-6666-6666-6666-666666666666', 'taylor.brown@example.com', 'Taylor Brown', 'sales_rep', '22222222-2222-2222-2222-222222222222')
ON CONFLICT (email) DO NOTHING;

-- Insert sample accounts
INSERT INTO accounts (id, name, domain, industry, employee_count, source) VALUES
  ('aaaa1111-1111-1111-1111-111111111111', 'Acme Corporation', 'acme.com', 'Technology', 500, 'salesforce'),
  ('aaaa2222-2222-2222-2222-222222222222', 'TechStart Inc', 'techstart.io', 'Technology', 150, 'salesforce'),
  ('aaaa3333-3333-3333-3333-333333333333', 'Global Finance Ltd', 'globalfinance.com', 'Financial Services', 2000, 'salesforce'),
  ('aaaa4444-4444-4444-4444-444444444444', 'HealthCare Plus', 'healthcareplus.org', 'Healthcare', 800, 'salesforce'),
  ('aaaa5555-5555-5555-5555-555555555555', 'RetailMax', 'retailmax.com', 'Retail', 1200, 'salesforce'),
  ('aaaa6666-6666-6666-6666-666666666666', 'CloudScale Systems', 'cloudscale.io', 'Technology', 300, 'apollo'),
  ('aaaa7777-7777-7777-7777-777777777777', 'DataDriven Analytics', 'datadriven.ai', 'Technology', 75, 'apollo'),
  ('aaaa8888-8888-8888-8888-888888888888', 'SecureNet Solutions', 'securenet.com', 'Cybersecurity', 200, 'manual'),
  ('aaaa9999-9999-9999-9999-999999999999', 'GreenEnergy Corp', 'greenenergy.com', 'Energy', 450, 'manual'),
  ('aaaabbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'MediaWorks Studio', 'mediaworks.tv', 'Media', 100, 'manual')
ON CONFLICT DO NOTHING;

-- Insert sample deals
INSERT INTO deals (id, account_id, name, amount, stage, close_date, owner_id, source) VALUES
  -- Alex's deals
  ('dddd1111-1111-1111-1111-111111111111', 'aaaa1111-1111-1111-1111-111111111111', 'Acme Enterprise License', 150000.00, 'negotiation', '2026-05-15', '33333333-3333-3333-3333-333333333333', 'salesforce'),
  ('dddd2222-2222-2222-2222-222222222222', 'aaaa2222-2222-2222-2222-222222222222', 'TechStart Platform Deal', 45000.00, 'proposal', '2026-04-30', '33333333-3333-3333-3333-333333333333', 'salesforce'),
  ('dddd3333-3333-3333-3333-333333333333', 'aaaa6666-6666-6666-6666-666666666666', 'CloudScale Integration', 75000.00, 'discovery', '2026-06-30', '33333333-3333-3333-3333-333333333333', 'manual'),
  -- Jordan's deals
  ('dddd4444-4444-4444-4444-444444444444', 'aaaa3333-3333-3333-3333-333333333333', 'Global Finance Data Solution', 200000.00, 'negotiation', '2026-05-01', '44444444-4444-4444-4444-444444444444', 'salesforce'),
  ('dddd5555-5555-5555-5555-555555555555', 'aaaa4444-4444-4444-4444-444444444444', 'HealthCare Analytics Suite', 80000.00, 'proposal', '2026-05-20', '44444444-4444-4444-4444-444444444444', 'salesforce'),
  -- Casey's deals
  ('dddd6666-6666-6666-6666-666666666666', 'aaaa5555-5555-5555-5555-555555555555', 'RetailMax POS Integration', 120000.00, 'discovery', '2026-06-15', '55555555-5555-5555-5555-555555555555', 'salesforce'),
  ('dddd7777-7777-7777-7777-777777777777', 'aaaa7777-7777-7777-7777-777777777777', 'DataDriven Pilot Program', 25000.00, 'proposal', '2026-04-25', '55555555-5555-5555-5555-555555555555', 'manual'),
  -- Taylor's deals
  ('dddd8888-8888-8888-8888-888888888888', 'aaaa8888-8888-8888-8888-888888888888', 'SecureNet Security Package', 95000.00, 'negotiation', '2026-05-10', '66666666-6666-6666-6666-666666666666', 'salesforce'),
  ('dddd9999-9999-9999-9999-999999999999', 'aaaa9999-9999-9999-9999-999999999999', 'GreenEnergy Monitoring System', 60000.00, 'discovery', '2026-07-01', '66666666-6666-6666-6666-666666666666', 'manual')
ON CONFLICT DO NOTHING;

-- Insert review weeks (last week and current week for each rep)
-- Last week (April 7, 2026)
INSERT INTO review_weeks (id, rep_id, week_start, status, manager_notes, reviewed_by, reviewed_at) VALUES
  ('rw111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '2026-04-06', 'reviewed', 'Great progress on Acme! Need to focus more on new outbound.', '11111111-1111-1111-1111-111111111111', '2026-04-13 10:00:00'),
  ('rw222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444', '2026-04-06', 'reviewed', 'Solid week. Global Finance is progressing well.', '11111111-1111-1111-1111-111111111111', '2026-04-13 11:00:00'),
  ('rw333333-3333-3333-3333-333333333333', '55555555-5555-5555-5555-555555555555', '2026-04-06', 'reviewed', 'Need to see more outbound activity. Lets discuss.', '22222222-2222-2222-2222-222222222222', '2026-04-13 14:00:00'),
  ('rw444444-4444-4444-4444-444444444444', '66666666-6666-6666-6666-666666666666', '2026-04-06', 'reviewed', 'Excellent work across the board!', '22222222-2222-2222-2222-222222222222', '2026-04-13 15:00:00')
ON CONFLICT DO NOTHING;

-- Current week (April 13, 2026)
INSERT INTO review_weeks (id, rep_id, week_start, status) VALUES
  ('rw555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', '2026-04-13', 'submitted'),
  ('rw666666-6666-6666-6666-666666666666', '44444444-4444-4444-4444-444444444444', '2026-04-13', 'draft'),
  ('rw777777-7777-7777-7777-777777777777', '55555555-5555-5555-5555-555555555555', '2026-04-13', 'submitted'),
  ('rw888888-8888-8888-8888-888888888888', '66666666-6666-6666-6666-666666666666', '2026-04-13', 'draft')
ON CONFLICT DO NOTHING;

-- Insert focus accounts for current week
INSERT INTO weekly_focus_accounts (review_week_id, account_id, priority, notes) VALUES
  -- Alex's focus accounts
  ('rw555555-5555-5555-5555-555555555555', 'aaaa1111-1111-1111-1111-111111111111', 1, 'Close the enterprise deal this week'),
  ('rw555555-5555-5555-5555-555555555555', 'aaaa2222-2222-2222-2222-222222222222', 2, 'Get proposal signed'),
  ('rw555555-5555-5555-5555-555555555555', 'aaaa6666-6666-6666-6666-666666666666', 3, 'Schedule discovery call'),
  -- Jordan's focus accounts
  ('rw666666-6666-6666-6666-666666666666', 'aaaa3333-3333-3333-3333-333333333333', 1, 'Final contract review'),
  ('rw666666-6666-6666-6666-666666666666', 'aaaa4444-4444-4444-4444-444444444444', 2, 'Demo scheduled Thursday'),
  -- Casey's focus accounts
  ('rw777777-7777-7777-7777-777777777777', 'aaaa5555-5555-5555-5555-555555555555', 1, 'Expand scope discussion'),
  ('rw777777-7777-7777-7777-777777777777', 'aaaa7777-7777-7777-7777-777777777777', 2, 'Pilot feedback review'),
  -- Taylor's focus accounts
  ('rw888888-8888-8888-8888-888888888888', 'aaaa8888-8888-8888-8888-888888888888', 1, 'Legal review in progress'),
  ('rw888888-8888-8888-8888-888888888888', 'aaaa9999-9999-9999-9999-999999999999', 2, 'Technical assessment');

-- Insert commitments for last week (with actuals - showing met/missed)
INSERT INTO weekly_commitments (review_week_id, commitment_type, description, target_value, actual_value, status) VALUES
  -- Alex's last week commitments
  ('rw111111-1111-1111-1111-111111111111', 'outbound_volume', 'Reach out to 20 new contacts', 20, 8, 'missed'),
  ('rw111111-1111-1111-1111-111111111111', 'meeting_target', 'Hold 5 discovery calls', 5, 6, 'exceeded'),
  ('rw111111-1111-1111-1111-111111111111', 'deal_action', 'Send proposal to Acme', NULL, NULL, 'met'),
  -- Jordan's last week commitments
  ('rw222222-2222-2222-2222-222222222222', 'outbound_volume', 'Email 25 prospects', 25, 28, 'exceeded'),
  ('rw222222-2222-2222-2222-222222222222', 'meeting_target', 'Complete 4 demos', 4, 4, 'met'),
  ('rw222222-2222-2222-2222-222222222222', 'follow_up', 'Follow up with 10 stale opps', 10, 7, 'missed'),
  -- Casey's last week commitments (poor performance - red flags)
  ('rw333333-3333-3333-3333-333333333333', 'outbound_volume', 'Contact 30 new leads', 30, 5, 'missed'),
  ('rw333333-3333-3333-3333-333333333333', 'meeting_target', 'Book 6 meetings', 6, 2, 'missed'),
  ('rw333333-3333-3333-3333-333333333333', 'pipeline_generation', 'Create $50k in new pipeline', NULL, NULL, 'missed'),
  -- Taylor's last week commitments (strong performance)
  ('rw444444-4444-4444-4444-444444444444', 'outbound_volume', 'Reach 15 new contacts', 15, 22, 'exceeded'),
  ('rw444444-4444-4444-4444-444444444444', 'meeting_target', 'Conduct 5 calls', 5, 5, 'met'),
  ('rw444444-4444-4444-4444-444444444444', 'deal_action', 'Get verbal on SecureNet', NULL, NULL, 'met');

-- Insert commitments for current week (pending - no actuals yet)
INSERT INTO weekly_commitments (review_week_id, commitment_type, description, target_value, target_amount, deal_id, account_id, status) VALUES
  -- Alex's current week commitments
  ('rw555555-5555-5555-5555-555555555555', 'outbound_volume', 'Reach out to 25 new contacts', 25, NULL, NULL, NULL, 'pending'),
  ('rw555555-5555-5555-5555-555555555555', 'meeting_target', 'Hold 4 discovery calls', 4, NULL, NULL, NULL, 'pending'),
  ('rw555555-5555-5555-5555-555555555555', 'deal_action', 'Close Acme Enterprise License', NULL, NULL, 'dddd1111-1111-1111-1111-111111111111', 'aaaa1111-1111-1111-1111-111111111111', 'pending'),
  ('rw555555-5555-5555-5555-555555555555', 'deal_action', 'Get TechStart proposal signed', NULL, NULL, 'dddd2222-2222-2222-2222-222222222222', 'aaaa2222-2222-2222-2222-222222222222', 'pending'),
  -- Jordan's current week commitments
  ('rw666666-6666-6666-6666-666666666666', 'outbound_volume', 'Email 20 new prospects', 20, NULL, NULL, NULL, 'pending'),
  ('rw666666-6666-6666-6666-666666666666', 'meeting_target', 'Complete 3 demos', 3, NULL, NULL, NULL, 'pending'),
  ('rw666666-6666-6666-6666-666666666666', 'pipeline_generation', 'Generate $75k in pipeline', NULL, 75000, NULL, NULL, 'pending'),
  -- Casey's current week commitments
  ('rw777777-7777-7777-7777-777777777777', 'outbound_volume', 'Contact 20 leads', 20, NULL, NULL, NULL, 'pending'),
  ('rw777777-7777-7777-7777-777777777777', 'meeting_target', 'Book 4 meetings', 4, NULL, NULL, NULL, 'pending'),
  ('rw777777-7777-7777-7777-777777777777', 'follow_up', 'Follow up on all open proposals', 5, NULL, NULL, NULL, 'pending'),
  -- Taylor's current week commitments
  ('rw888888-8888-8888-8888-888888888888', 'outbound_volume', 'Reach 18 new contacts', 18, NULL, NULL, NULL, 'pending'),
  ('rw888888-8888-8888-8888-888888888888', 'deal_action', 'Get SecureNet contract signed', NULL, NULL, 'dddd8888-8888-8888-8888-888888888888', 'aaaa8888-8888-8888-8888-888888888888', 'pending');

-- Insert sample activities for current week
INSERT INTO activities (source, activity_type, rep_id, account_id, deal_id, contact_name, contact_email, direction, duration_seconds, occurred_at) VALUES
  -- Alex's activities
  ('gong', 'call', '33333333-3333-3333-3333-333333333333', 'aaaa1111-1111-1111-1111-111111111111', 'dddd1111-1111-1111-1111-111111111111', 'John Davis', 'john.davis@acme.com', 'outbound', 1800, '2026-04-14 10:00:00'),
  ('gong', 'call', '33333333-3333-3333-3333-333333333333', 'aaaa1111-1111-1111-1111-111111111111', 'dddd1111-1111-1111-1111-111111111111', 'Lisa Wong', 'lisa.wong@acme.com', 'outbound', 2400, '2026-04-14 14:00:00'),
  ('nektar', 'email', '33333333-3333-3333-3333-333333333333', 'aaaa2222-2222-2222-2222-222222222222', 'dddd2222-2222-2222-2222-222222222222', 'Tom Miller', 'tom@techstart.io', 'outbound', NULL, '2026-04-14 09:30:00'),
  ('nektar', 'email', '33333333-3333-3333-3333-333333333333', 'aaaa6666-6666-6666-6666-666666666666', NULL, 'Sara Lee', 'sara@cloudscale.io', 'outbound', NULL, '2026-04-14 11:00:00'),
  ('salesforce', 'meeting', '33333333-3333-3333-3333-333333333333', 'aaaa1111-1111-1111-1111-111111111111', 'dddd1111-1111-1111-1111-111111111111', 'Executive Team', NULL, NULL, 3600, '2026-04-15 09:00:00'),
  -- Jordan's activities
  ('gong', 'call', '44444444-4444-4444-4444-444444444444', 'aaaa3333-3333-3333-3333-333333333333', 'dddd4444-4444-4444-4444-444444444444', 'Mark Roberts', 'mark.roberts@globalfinance.com', 'outbound', 2700, '2026-04-14 11:00:00'),
  ('nektar', 'email', '44444444-4444-4444-4444-444444444444', 'aaaa3333-3333-3333-3333-333333333333', 'dddd4444-4444-4444-4444-444444444444', 'CFO Office', 'cfo@globalfinance.com', 'outbound', NULL, '2026-04-14 15:00:00'),
  ('nektar', 'email', '44444444-4444-4444-4444-444444444444', 'aaaa4444-4444-4444-4444-444444444444', 'dddd5555-5555-5555-5555-555555555555', 'Dr. Smith', 'dr.smith@healthcareplus.org', 'outbound', NULL, '2026-04-15 08:30:00'),
  -- Casey's activities (fewer - showing potential concern)
  ('nektar', 'email', '55555555-5555-5555-5555-555555555555', 'aaaa5555-5555-5555-5555-555555555555', 'dddd6666-6666-6666-6666-666666666666', 'Retail Buyer', 'buyer@retailmax.com', 'outbound', NULL, '2026-04-14 10:00:00'),
  ('gong', 'call', '55555555-5555-5555-5555-555555555555', 'aaaa7777-7777-7777-7777-777777777777', 'dddd7777-7777-7777-7777-777777777777', 'Data Team', 'team@datadriven.ai', 'inbound', 1200, '2026-04-14 16:00:00'),
  -- Taylor's activities (strong activity)
  ('gong', 'call', '66666666-6666-6666-6666-666666666666', 'aaaa8888-8888-8888-8888-888888888888', 'dddd8888-8888-8888-8888-888888888888', 'Security Director', 'security@securenet.com', 'outbound', 3000, '2026-04-14 09:00:00'),
  ('gong', 'call', '66666666-6666-6666-6666-666666666666', 'aaaa8888-8888-8888-8888-888888888888', 'dddd8888-8888-8888-8888-888888888888', 'Legal Team', 'legal@securenet.com', 'outbound', 1800, '2026-04-14 14:00:00'),
  ('nektar', 'email', '66666666-6666-6666-6666-666666666666', 'aaaa9999-9999-9999-9999-999999999999', 'dddd9999-9999-9999-9999-999999999999', 'Project Lead', 'project@greenenergy.com', 'outbound', NULL, '2026-04-14 11:30:00'),
  ('salesforce', 'crm_update', '66666666-6666-6666-6666-666666666666', 'aaaa8888-8888-8888-8888-888888888888', 'dddd8888-8888-8888-8888-888888888888', NULL, NULL, NULL, NULL, '2026-04-14 17:00:00'),
  ('apollo', 'linkedin', '66666666-6666-6666-6666-666666666666', NULL, NULL, 'New Prospect', 'prospect@newcompany.com', 'outbound', NULL, '2026-04-15 10:00:00');

-- Insert sample review comments
INSERT INTO review_comments (review_week_id, user_id, content, created_at) VALUES
  ('rw111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'The Acme progress looks great! What''s blocking the outbound volume?', '2026-04-13 10:30:00'),
  ('rw111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', 'Focused heavily on closing Acme. Will prioritize outbound this week.', '2026-04-13 11:00:00'),
  ('rw333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', 'We need to discuss your outbound strategy. The numbers are concerning.', '2026-04-13 14:30:00'),
  ('rw333333-3333-3333-3333-333333333333', '55555555-5555-5555-5555-555555555555', 'Understood. Had some personal issues but I''m back on track.', '2026-04-13 15:00:00');
