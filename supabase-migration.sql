-- Jalankan sekali di Supabase Dashboard > SQL Editor.
-- Kolom ini dipakai oleh checkout antar dan detail produk.

alter table public.orders
  add column if not exists fulfillment_method text default 'Ambil di Toko',
  add column if not exists delivery_address text,
  add column if not exists diskon numeric not null default 0,
  add column if not exists guarantee_identity text,
  add column if not exists dp_amount numeric not null default 0,
  add column if not exists payment_status text not null default 'Lunas';

alter table public.products
  add column if not exists description text,
  add column if not exists specifications text;

-- Refresh schema cache PostgREST setelah perubahan struktur.
notify pgrst, 'reload schema';

-- Izinkan tombol Reset Riwayat menghapus data transaksi melalui client aplikasi.
-- Jalankan bagian ini jika request DELETE sebelumnya tidak menghapus baris karena RLS.
drop policy if exists "Allow public delete order items" on public.order_items;
create policy "Allow public delete order items"
  on public.order_items for delete
  to anon, authenticated
  using (true);

drop policy if exists "Allow public delete orders" on public.orders;
create policy "Allow public delete orders"
  on public.orders for delete
  to anon, authenticated
  using (true);
