const { createClient } = require('@supabase/supabase-js');
require('dotenv').config();

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;
const supabaseServiceRoleKey =
  process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;

function readJwtRole(token) {
  try {
    const parts = token.split('.');
    if (parts.length < 2) return null;
    const payload = JSON.parse(
      Buffer.from(parts[1], 'base64url').toString('utf8'),
    );
    return payload.role || null;
  } catch (_) {
    return null;
  }
}

if (!supabaseUrl) {
  throw new Error('SUPABASE_URL is required.');
}

if (!supabaseAnonKey) {
  throw new Error('SUPABASE_ANON_KEY is required.');
}

if (!supabaseServiceRoleKey) {
  throw new Error(
    'SUPABASE_SERVICE_ROLE_KEY or SUPABASE_SERVICE_KEY is required.',
  );
}

const serviceRole = readJwtRole(supabaseServiceRoleKey);
if (serviceRole !== 'service_role') {
  throw new Error(
    'Supabase service role key is invalid. Set SUPABASE_SERVICE_ROLE_KEY to the service_role key from the Supabase dashboard, not the anon key.',
  );
}

// Create Supabase client with anon key for public operations
const supabase = createClient(supabaseUrl, supabaseAnonKey);

// Create Supabase client with service role key for admin operations
const supabaseAdmin = createClient(supabaseUrl, supabaseServiceRoleKey);

module.exports = { supabase, supabaseAdmin, supabaseUrl };
