const { createClient } = require('@supabase/supabase-js');
const dotenv = require('dotenv');
dotenv.config();

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

async function checkDb() {
  console.log('--- Checking Conversations ---');
  const { data: convs, error: convError } = await supabase.from('conversations').select('*');
  if (convError) console.error('Conv Error:', convError);
  else console.log('Conversations count:', convs.length, convs);

  console.log('--- Checking Messages ---');
  const { data: msgs, error: msgError } = await supabase.from('messages').select('*').limit(5);
  if (msgError) console.error('Msg Error:', msgError);
  else console.log('Messages sample:', msgs);

  console.log('--- Checking Profiles ---');
  const { data: profiles, error: profError } = await supabase.from('profiles').select('id, username').limit(5);
  if (profError) console.error('Prof Error:', profError);
  else console.log('Profiles sample:', profiles);
}

checkDb();
