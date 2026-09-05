-- Jalankan sekali di Supabase Dashboard > SQL Editor.
-- Kolom ini dipakai oleh checkout antar dan detail produk.

alter table public.orders
  add column if not exists fulfillment_method text default 'Ambil di Toko',
  add column if not exists delivery_address text;

alter table public.products
  add column if not exists description text,
  add column if not exists specifications text;

-- Refresh schema cache PostgREST setelah perubahan struktur.
notify pgrst, 'reload schema';
