import { createClient } from '@supabase/supabase-js'

const supabaseUrl = 'https://apvyqqumaajdewqrjimm.supabase.co'
const supabaseAnonKey = 'sb_publishable_jiUnB95CIskv7YwSmIyFFg_Yfuv1sPh'

export const supabase = createClient(supabaseUrl, supabaseAnonKey)

// jsgd