<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { supabase } from './supabase'
import jsPDF from 'jspdf'
import * as XLSX from 'xlsx'

// PIN Akses Admin/Kasir (Bisa kamu ganti)
const ADMIN_PIN = '1234'
const ADMIN_ROUTE = '/admin'
const ADMIN_WHATSAPP = '6289517829189'
const pinInput = ref('')
const pinError = ref(false)

// Mode POV: 'customer' (Pelanggan) atau 'admin' (Kasir/Admin)
const currentPOV = ref('customer')
const isAdminLoggedIn = ref(false)
const showSplash = ref(true)
const splashVisible = ref(true)
let splashTimer
let splashFadeTimer

// Tab Admin: 'pos', 'online_orders', 'orders', 'reports', 'inventory'
const activeTab = ref('pos')

// State Inventaris & Produk
const products = ref([])
const loading = ref(true)
const uploading = ref(false)
const isEditing = ref(false)
const editingId = ref(null)

const newProduct = ref({
  name: '',
  category: 'Tenda',
  price_per_day: '',
  total_stock: '',
  image_url: '',
  description: '',
  specifications: ''
})
const selectedFile = ref(null)

// Search & Filter
const searchProduct = ref('')
const selectedCategoryFilter = ref('')
const searchOrder = ref('')
const statusOrderFilter = ref('')

// State Transaksi / Booking
const cart = ref([])
const customerName = ref('')
const customerPhone = ref('')
const startDate = ref('')
const endDate = ref('')
const fulfillmentMethod = ref('Ambil di Toko')
const deliveryAddress = ref('')
const paymentMethod = ref('Tunai')
const amountPaid = ref(0)
const proofFile = ref(null)
const bookingSuccessModal = ref(false)
const checkoutModalOpen = ref(false)
const lastBookingData = ref(null)
const selectedProduct = ref(null)

// State Riwayat & Modal
const orders = ref([])
const receiptModalData = ref(null)
const returnModalOrder = ref(null)
const lateDaysInput = ref(0)
const damageFeeInput = ref(0)
const returnNotesInput = ref('')

// 1. Fetch Data Produk
const fetchProducts = async () => {
  loading.value = true
  const { data, error } = await supabase
    .from('products')
    .select('*')
    .order('created_at', { ascending: false })

  if (error) console.error(error)
  else products.value = data || []
  loading.value = false
}

// 2. Fetch Riwayat Transaksi
const fetchOrders = async () => {
  const { data, error } = await supabase
    .from('orders')
    .select('*, order_items(*)')
    .order('created_at', { ascending: false })

  if (error) console.error('Error fetching orders:', error)
  else orders.value = data || []
}

// Auth Admin PIN
const loginAdmin = () => {
  if (pinInput.value === ADMIN_PIN) {
    isAdminLoggedIn.value = true
    currentPOV.value = 'admin'
    pinError.value = false
    pinInput.value = ''
  } else {
    pinError.value = true
  }
}

const closeAdminLogin = () => {
  window.history.replaceState({}, '', '/')
  currentPOV.value = 'customer'
  pinInput.value = ''
  pinError.value = false
}

const logoutAdmin = () => {
  isAdminLoggedIn.value = false
  closeAdminLogin()
}

// Computed Filters
const filteredProducts = computed(() => {
  return products.value.filter(item => {
    const matchesSearch = item.name.toLowerCase().includes(searchProduct.value.toLowerCase())
    const matchesCategory = selectedCategoryFilter.value ? item.category === selectedCategoryFilter.value : true
    return matchesSearch && matchesCategory
  })
})

const pendingOnlineOrders = computed(() => {
  return orders.value.filter(o => o.status === 'Menunggu Konfirmasi')
})

const getDueDateStatus = (order) => {
  if (order.status === 'Selesai') return { label: 'Selesai', color: 'bg-slate-100 text-slate-600 border-slate-200', isOverdue: false, isToday: false }
  if (order.status === 'Menunggu Konfirmasi') return { label: 'Menunggu Approval', color: 'bg-amber-100 text-amber-800 border-amber-300', isOverdue: false, isToday: false }
  
  const today = new Date()
  today.setHours(0,0,0,0)
  const due = new Date(order.end_date)
  due.setHours(0,0,0,0)

  const diffTime = due - today
  const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24))

  if (diffDays < 0) {
    return { label: `Terlambat ${Math.abs(diffDays)} Hari`, color: 'bg-red-100 text-red-800 border-red-300 font-bold', isOverdue: true, isToday: false, lateDays: Math.abs(diffDays) }
  } else if (diffDays === 0) {
    return { label: 'Jatuh Tempo Hari Ini!', color: 'bg-amber-100 text-amber-800 border-amber-300 font-bold animate-pulse', isOverdue: false, isToday: true, lateDays: 0 }
  } else {
    return { label: `Sisa ${diffDays} Hari`, color: 'bg-blue-50 text-blue-700 border-blue-200', isOverdue: false, isToday: false, lateDays: 0 }
  }
}

const filteredOrders = computed(() => {
  return orders.value.filter(item => {
    const matchesSearch = item.customer_name.toLowerCase().includes(searchOrder.value.toLowerCase()) ||
                          item.customer_phone.includes(searchOrder.value)
    
    let matchesStatus = true
    if (statusOrderFilter.value === 'Aktif') matchesStatus = item.status === 'Aktif'
    else if (statusOrderFilter.value === 'Pending') matchesStatus = item.status === 'Menunggu Konfirmasi'
    else if (statusOrderFilter.value === 'Selesai') matchesStatus = item.status === 'Selesai'
    else if (statusOrderFilter.value === 'Terlambat') {
      const dueInfo = getDueDateStatus(item)
      matchesStatus = item.status === 'Aktif' && dueInfo.isOverdue
    }

    return matchesSearch && matchesStatus
  })
})

const stats = computed(() => {
  const now = new Date()
  const todayStr = now.toISOString().split('T')[0]
  const currentMonthStr = todayStr.substring(0, 7)

  let totalIncomeAll = 0
  let totalIncomeToday = 0
  let totalIncomeMonth = 0
  let cashIncome = 0
  let nonCashIncome = 0

  const productCounts = {}

  orders.value.forEach(order => {
    if (order.status === 'Ditolak' || order.status === 'Menunggu Konfirmasi') return

    const finalTotal = Number(order.total_price || 0) + Number(order.late_fee || 0) + Number(order.damage_fee || 0)
    totalIncomeAll += finalTotal

    const orderDate = order.created_at ? order.created_at.split('T')[0] : ''
    if (orderDate === todayStr) totalIncomeToday += finalTotal
    if (orderDate.startsWith(currentMonthStr)) totalIncomeMonth += finalTotal

    if (order.payment_method === 'Tunai') cashIncome += finalTotal
    else nonCashIncome += finalTotal

    if (order.order_items && Array.isArray(order.order_items)) {
      order.order_items.forEach(item => {
        productCounts[item.product_name] = (productCounts[item.product_name] || 0) + item.quantity
      })
    }
  })

  const sortedProducts = Object.entries(productCounts)
    .map(([name, qty]) => ({ name, qty }))
    .sort((a, b) => b.qty - a.qty)
    .slice(0, 3)

  const activeOrders = orders.value.filter(o => o.status === 'Aktif')
  const overdueOrders = activeOrders.filter(o => getDueDateStatus(o).isOverdue)

  return {
    totalIncomeAll,
    totalIncomeToday,
    totalIncomeMonth,
    cashIncome,
    nonCashIncome,
    topProducts: sortedProducts,
    activeOrdersCount: activeOrders.length,
    overdueOrdersCount: overdueOrders.length,
    pendingCount: pendingOnlineOrders.value.length
  }
})

// Keranjang
const addToCart = (product) => {
  const existing = cart.value.find(item => item.id === product.id)
  if (existing) {
    if (existing.qty < product.total_stock) existing.qty++
    else alert('Jumlah melebihi stok yang tersedia!')
  } else {
    cart.value.push({
      id: product.id,
      name: product.name,
      price_per_day: product.price_per_day,
      qty: 1,
      image_url: product.image_url
    })
  }
}

const showProductDetails = (product) => {
  selectedProduct.value = product
}

const closeProductDetails = () => {
  selectedProduct.value = null
}

const updateQty = (id, delta) => {
  const item = cart.value.find(i => i.id === id)
  if (!item) return
  const product = products.value.find(p => p.id === id)
  
  if (delta > 0 && item.qty >= product.total_stock) {
    alert('Stok tidak mencukupi!')
    return
  }

  item.qty += delta
  if (item.qty <= 0) cart.value = cart.value.filter(i => i.id !== id)
  if (cart.value.length === 0) checkoutModalOpen.value = false
}

const totalDays = computed(() => {
  if (!startDate.value || !endDate.value) return 0
  const start = new Date(startDate.value)
  const end = new Date(endDate.value)
  const diffTime = end - start
  const days = Math.ceil(diffTime / (1000 * 60 * 60 * 24))
  return days > 0 ? days : 0
})

const today = new Date().toISOString().split('T')[0]
const minimumEndDate = computed(() => startDate.value || today)
const cartItemCount = computed(() => cart.value.reduce((total, item) => total + item.qty, 0))

const totalPrice = computed(() => {
  const subtotalPerDay = cart.value.reduce((sum, item) => sum + (item.price_per_day * item.qty), 0)
  return subtotalPerDay * totalDays.value
})

const changeAmount = computed(() => {
  if (paymentMethod.value !== 'Tunai') return 0
  const change = Number(amountPaid.value) - totalPrice.value
  return change > 0 ? change : 0
})

// Upload Bukti Pembayaran Online
const handleProofChange = (e) => { proofFile.value = e.target.files[0] }

const selectPaymentMethod = (method) => {
  paymentMethod.value = method
  proofFile.value = null
}

const selectFulfillmentMethod = (method) => {
  fulfillmentMethod.value = method
  if (method === 'Ambil di Toko') deliveryAddress.value = ''
}

const uploadProof = async (file) => {
  const filePath = `proofs/${Date.now()}.${file.name.split('.').pop()}`
  const { error } = await supabase.storage.from('product-images').upload(filePath, file)
  if (error) throw error
  const { data } = supabase.storage.from('product-images').getPublicUrl(filePath)
  return data.publicUrl
}

// Proses Transaksi (Sewa Offline Kasir ATAU Booking Online Pelanggan)
const processCheckout = async (isCustomerBooking = false) => {
  if (!customerName.value || !customerPhone.value || !startDate.value || !endDate.value) {
    alert('Mohon lengkapi data penyewa dan tanggal sewa!')
    return
  }
  if (cart.value.length === 0) {
    alert('Keranjang sewa masih kosong!')
    return
  }
  if (endDate.value <= startDate.value) {
    alert('Tanggal selesai harus setelah tanggal mulai!')
    return
  }
  if (totalDays.value <= 0) {
    alert('Tanggal selesai harus setelah tanggal mulai sewa!')
    return
  }
  if (isCustomerBooking && fulfillmentMethod.value === 'Antar' && !deliveryAddress.value.trim()) {
    alert('Mohon isi alamat pengantaran!')
    return
  }

  if (isCustomerBooking && paymentMethod.value === 'QRIS' && !proofFile.value) {
    alert('Silakan upload bukti pembayaran QRIS sebelum mengirim booking!')
    return
  }

  if (!isCustomerBooking && paymentMethod.value === 'Tunai' && Number(amountPaid.value) < totalPrice.value) {
    alert('Uang pembayaran tunai masih kurang!')
    return
  }

  try {
    let proofUrl = null
    if (isCustomerBooking && proofFile.value) {
      proofUrl = await uploadProof(proofFile.value)
    }

    const orderStatus = isCustomerBooking ? 'Menunggu Konfirmasi' : 'Aktif'
    const finalPaid = isCustomerBooking ? 0 : (paymentMethod.value === 'Tunai' ? Number(amountPaid.value) : totalPrice.value)
    const finalChange = isCustomerBooking ? 0 : (paymentMethod.value === 'Tunai' ? changeAmount.value : 0)

    const { data: orderData, error: orderError } = await supabase
      .from('orders')
      .insert([{
        customer_name: customerName.value,
        customer_phone: customerPhone.value,
        start_date: startDate.value,
        end_date: endDate.value,
        total_days: totalDays.value,
        total_price: totalPrice.value,
        ...(isCustomerBooking ? {
          fulfillment_method: fulfillmentMethod.value,
          delivery_address: fulfillmentMethod.value === 'Antar' ? deliveryAddress.value.trim() : null
        } : {}),
        status: orderStatus,
        payment_method: paymentMethod.value,
        amount_paid: finalPaid,
        change_amount: finalChange,
        late_fee: 0,
        damage_fee: 0,
        order_type: isCustomerBooking ? 'online' : 'offline',
        proof_of_payment: proofUrl
      }])
      .select()
      .single()

    if (orderError) throw orderError

    const itemsPayload = cart.value.map(item => ({
      order_id: orderData.id,
      product_id: item.id,
      product_name: item.name,
      quantity: item.qty,
      price_per_day: item.price_per_day,
      subtotal: item.price_per_day * item.qty * totalDays.value
    }))

    const { error: itemsError } = await supabase
      .from('order_items')
      .insert(itemsPayload)

    if (itemsError) throw itemsError

    // Potong stok langsung jika transaksi kasir
    if (!isCustomerBooking) {
      for (const item of cart.value) {
        const product = products.value.find(p => p.id === item.id)
        if (product) {
          const newStock = Math.max(0, product.total_stock - item.qty)
          await supabase.from('products').update({ total_stock: newStock }).eq('id', item.id)
        }
      }
    }

    if (isCustomerBooking) {
      lastBookingData.value = { ...orderData, order_items: itemsPayload }
      bookingSuccessModal.value = true
    } else {
      alert('Transaksi Sewa Berhasil Dibuat!')
      receiptModalData.value = { ...orderData, order_items: itemsPayload }
    }

    cart.value = []
    checkoutModalOpen.value = false
    customerName.value = ''
    customerPhone.value = ''
    startDate.value = ''
    endDate.value = ''
    fulfillmentMethod.value = 'Ambil di Toko'
    deliveryAddress.value = ''
    paymentMethod.value = 'Tunai'
    amountPaid.value = 0
    proofFile.value = null
    fetchProducts()
    fetchOrders()

  } catch (err) {
    alert('Gagal memproses transaksi: ' + err.message)
  }
}

// Konfirmasi Pesanan Online oleh Admin
const approveOnlineOrder = async (order) => {
  try {
    // Kurangi stok barang
    if (order.order_items && order.order_items.length > 0) {
      for (const item of order.order_items) {
        const product = products.value.find(p => p.id === item.product_id)
        if (product) {
          if (product.total_stock < item.quantity) {
            alert(`Stok ${product.name} tidak mencukupi untuk menyetujui booking ini!`)
            return
          }
          await supabase.from('products').update({ total_stock: product.total_stock - item.quantity }).eq('id', item.product_id)
        }
      }
    }

    await supabase.from('orders').update({ status: 'Aktif' }).eq('id', order.id)
    alert('Booking berhasil disetujui! Stok otomatis dipotong.')
    fetchProducts()
    fetchOrders()
  } catch (err) {
    alert('Gagal menyetujui booking: ' + err.message)
  }
}

const rejectOnlineOrder = async (order) => {
  if (confirm(`Tolak pesanan booking dari ${order.customer_name}?`)) {
    await supabase.from('orders').update({ status: 'Ditolak' }).eq('id', order.id)
    fetchOrders()
  }
}

// Pengembalian & Denda
const openReturnModal = (order) => {
  returnModalOrder.value = order
  const dueInfo = getDueDateStatus(order)
  lateDaysInput.value = dueInfo.lateDays || 0
  damageFeeInput.value = 0
  returnNotesInput.value = ''
}

const calculatedLateFee = computed(() => {
  if (!returnModalOrder.value || lateDaysInput.value <= 0) return 0
  const ratePerDay = returnModalOrder.value.total_price / returnModalOrder.value.total_days
  return Math.round(ratePerDay * lateDaysInput.value)
})

const submitReturn = async () => {
  if (!returnModalOrder.value) return
  const order = returnModalOrder.value
  const lateFee = calculatedLateFee.value
  const damageFee = Number(damageFeeInput.value || 0)

  try {
    await supabase.from('orders').update({
      status: 'Selesai',
      late_fee: lateFee,
      damage_fee: damageFee,
      return_notes: returnNotesInput.value
    }).eq('id', order.id)

    if (order.order_items && order.order_items.length > 0) {
      for (const item of order.order_items) {
        const product = products.value.find(p => p.id === item.product_id)
        if (product) {
          await supabase.from('products').update({ total_stock: product.total_stock + item.quantity }).eq('id', item.product_id)
        }
      }
    }

    alert('Pengembalian berhasil ditandai & stok telah dikembalikan!')
    returnModalOrder.value = null
    fetchProducts()
    fetchOrders()
  } catch (err) {
    alert('Gagal memproses pengembalian: ' + err.message)
  }
}

// WA Reminders & Struk
const sendReminderWhatsApp = (order) => {
  let phone = order.customer_phone.replace(/[^0-9]/g, '')
  if (phone.startsWith('0')) phone = '62' + phone.slice(1)
  const dueInfo = getDueDateStatus(order)
  
  let msg = `Halo Kak *${order.customer_name}*,\nSekadar mengingatkan masa sewa alat camping Anda di Jabal Outdoor Store `
  if (dueInfo.isOverdue) msg += `telah *TERLAMBAT ${dueInfo.lateDays} HARI* dari jadwal (${order.end_date}). Mohon segera dikembalikan.`
  else msg += `akan berakhir pada tanggal *${order.end_date}*. Terima kasih! 🙏`

  window.open(`https://wa.me/${phone}?text=${encodeURIComponent(msg)}`, '_blank')
}

const buildWhatsAppOrderMessage = (order, isCustomerConfirmation = false) => {
  let itemsText = ''
  if (order.order_items) {
    order.order_items.forEach((item, index) => {
      itemsText += `${index + 1}. *${item.product_name}* x${item.quantity}\n`
    })
  }

  const baseTotal = Number(order.total_price || 0)
  const lateFee = Number(order.late_fee || 0)
  const damageFee = Number(order.damage_fee || 0)
  const finalTotal = baseTotal + lateFee + damageFee
  const fulfillment = order.fulfillment_method || 'Ambil di Toko'
  const deliveryText = fulfillment === 'Antar' && order.delivery_address
    ? `\nAlamat Antar: ${order.delivery_address}`
    : ''
  const feeText = `${lateFee > 0 ? `\nDenda Keterlambatan: Rp ${lateFee.toLocaleString('id-ID')}` : ''}${damageFee > 0 ? `\nDenda Kerusakan/Hilang: Rp ${damageFee.toLocaleString('id-ID')}` : ''}`
  const goSendText = fulfillment === 'Antar'
    ? '\nCatatan: Biaya pengantaran GoSend belum termasuk total sewa. Estimasi biaya akan dikonfirmasi melalui WhatsApp.'
    : ''

  const title = isCustomerConfirmation ? 'KONFIRMASI BOOKING BARU' : 'NOTA SEWA'
  const greeting = isCustomerConfirmation ? 'Ada booking baru dari pelanggan:' : `Halo Kak *${order.customer_name}*,\nBerikut rincian sewa Anda:`
  const statusText = isCustomerConfirmation ? 'Menunggu Konfirmasi Admin' : order.status

  return `🏕️ *JABAL OUTDOOR STORE - ${title}*\n${greeting}\n${itemsText}Periode: ${order.start_date} s/d ${order.end_date}\nMetode Pengambilan: *${fulfillment}*${deliveryText}${goSendText}\nSubtotal Sewa: Rp ${baseTotal.toLocaleString('id-ID')}${feeText}\n*TOTAL AKHIR: Rp ${finalTotal.toLocaleString('id-ID')}*\nStatus: *${statusText}*\n${isCustomerConfirmation ? 'Mohon konfirmasi booking ini. Terima kasih.' : 'Terima kasih!'} `
}

const sendWhatsAppNota = (order) => {
  let phone = order.customer_phone.replace(/[^0-9]/g, '')
  if (phone.startsWith('0')) phone = '62' + phone.slice(1)
  const msg = buildWhatsAppOrderMessage(order)
  window.open(`https://wa.me/${phone}?text=${encodeURIComponent(msg)}`, '_blank')
}

const sendBookingConfirmationToAdmin = (order) => {
  const msg = buildWhatsAppOrderMessage(order, true)
  window.open(`https://wa.me/${ADMIN_WHATSAPP}?text=${encodeURIComponent(msg)}`, '_blank')
}

// Export Excel & PDF
const exportToExcel = () => {
  const excelData = orders.value.map(order => ({
    'ID Transaksi': order.id,
    'Tipe': order.order_type || 'offline',
    'Tanggal Transaksi': order.created_at ? order.created_at.split('T')[0] : '',
    'Nama Pelanggan': order.customer_name,
    'No WA': order.customer_phone,
    'Tgl Mulai': order.start_date,
    'Tgl Kembali': order.end_date,
    'Durasi (Hari)': order.total_days,
    'Total (Rp)': Number(order.total_price),
    'Status': order.status
  }))
  const ws = XLSX.utils.json_to_sheet(excelData)
  const wb = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(wb, ws, 'Laporan Keuangan')
  XLSX.writeFile(wb, `Laporan_JabalOutdoor_${new Date().toISOString().split('T')[0]}.xlsx`)
}

const exportToPDF = () => {
  const doc = new jsPDF()
  doc.setFontSize(16)
  doc.text('JABAL OUTDOOR STORE - LAPORAN KEUANGAN', 14, 15)
  doc.setFontSize(10)
  doc.text(`Total Pendapatan: Rp ${stats.value.totalIncomeAll.toLocaleString('id-ID')}`, 14, 25)
  doc.text(`Total Transaksi: ${orders.value.length}`, 14, 30)

  let y = 40
  orders.value.slice(0, 25).forEach((o, i) => {
    doc.text(`${i+1}. ${o.customer_name} | ${o.start_date} s/d ${o.end_date} | Rp ${Number(o.total_price).toLocaleString('id-ID')} | [${o.status}]`, 14, y)
    y += 6
  })
  doc.save(`Laporan_JabalOutdoor_${new Date().toISOString().split('T')[0]}.pdf`)
}

const printReceipt = () => { window.print() }

// Inventaris Logic
const handleFileChange = (e) => { selectedFile.value = e.target.files[0] }
const uploadImage = async (file) => {
  const filePath = `${Date.now()}.${file.name.split('.').pop()}`
  const { error } = await supabase.storage.from('product-images').upload(filePath, file)
  if (error) throw error
  const { data } = supabase.storage.from('product-images').getPublicUrl(filePath)
  return data.publicUrl
}

const saveProduct = async () => {
  if (!newProduct.value.name || !newProduct.value.price_per_day) return alert('Isi data dengan benar!')
  try {
    uploading.value = true
    let imageUrl = newProduct.value.image_url
    if (selectedFile.value) imageUrl = await uploadImage(selectedFile.value)

    const payload = {
      name: newProduct.value.name,
      category: newProduct.value.category,
      price_per_day: Number(newProduct.value.price_per_day),
      total_stock: Number(newProduct.value.total_stock),
      image_url: imageUrl || null,
      description: newProduct.value.description?.trim() || null,
      specifications: newProduct.value.specifications?.trim() || null
    }

    if (isEditing.value) await supabase.from('products').update(payload).eq('id', editingId.value)
    else await supabase.from('products').insert([payload])
    resetForm()
    fetchProducts()
  } catch (e) { alert(e.message) } 
  finally { uploading.value = false }
}

const editProduct = (item) => {
  isEditing.value = true
  editingId.value = item.id
  newProduct.value = { ...item }
}

const deleteProduct = async (id, name) => {
  if (confirm(`Hapus ${name}?`)) {
    await supabase.from('products').delete().eq('id', id)
    fetchProducts()
  }
}

const resetForm = () => {
  isEditing.value = false
  editingId.value = null
  selectedFile.value = null
  newProduct.value = {
    name: '',
    category: 'Tenda',
    price_per_day: '',
    total_stock: '',
    image_url: '',
    description: '',
    specifications: ''
  }
}

onMounted(() => {
  fetchProducts()
  fetchOrders()

  if (window.location.pathname === ADMIN_ROUTE || window.location.hash === '#admin') {
    currentPOV.value = 'admin_login'
  }

  splashTimer = window.setTimeout(() => {
    showSplash.value = false
    splashFadeTimer = window.setTimeout(() => {
      splashVisible.value = false
    }, 500)
  }, 2000)
})

onUnmounted(() => {
  window.clearTimeout(splashTimer)
  window.clearTimeout(splashFadeTimer)
})
</script>

<template>
  <div class="min-h-screen bg-slate-100 font-sans pb-12">

    <!-- SPLASH SCREEN -->
    <div
      v-if="splashVisible"
      class="fixed inset-0 z-[100] flex flex-col items-center justify-center bg-emerald-950 text-white transition-opacity duration-500 ease-out"
      :class="showSplash ? 'opacity-100' : 'opacity-0 pointer-events-none'"
      aria-label="Memuat Jabal Outdoor Store"
    >
      <div class="flex flex-col items-center text-center px-6">
        <div class="splash-logo mb-5 flex h-28 w-28 items-center justify-center overflow-hidden rounded-3xl bg-emerald-950/60">
          <img src="/logo-jabal.png" alt="Logo Jabal Outdoor" class="h-full w-full object-cover" />
        </div>
        <h1 class="splash-title text-2xl font-black tracking-wide sm:text-3xl">JABAL OUTDOOR STORE</h1>
        <p class="splash-tagline mt-2 text-sm text-emerald-200 sm:text-base">Sewa Alat Camping &amp; Outdoor</p>
        <div class="splash-loading mt-10 flex items-center gap-2 text-xs text-emerald-300">
          <span class="splash-spinner h-4 w-4 rounded-full border-2 border-emerald-700 border-t-emerald-200"></span>
          <span>Menyiapkan petualanganmu...</span>
        </div>
      </div>
    </div>
    
    <!-- TOP BAR NAVIGATION -->
    <header class="bg-emerald-950 text-white p-3 shadow-md border-b border-emerald-800 print:hidden">
      <div class="max-w-7xl mx-auto flex justify-between items-center text-xs">
        <div class="flex items-center gap-3">
          <img src="/logo-jabal.png" alt="Logo Jabal Outdoor" class="w-10 h-10 rounded-lg object-cover border border-emerald-700" />
          <div>
            <span class="block font-black tracking-wide text-sm">JABAL OUTDOOR STORE</span>
            <span class="text-[10px] text-emerald-200">Sewa perlengkapan outdoor</span>
          </div>
        </div>

        <div v-if="isAdminLoggedIn" class="flex items-center space-x-3">
          <button v-if="isAdminLoggedIn" @click="logoutAdmin" class="bg-red-600 hover:bg-red-700 text-white px-2 py-1 rounded font-bold">
            Logout Admin
          </button>
        </div>
      </div>
    </header>

    <!-- ========================================== -->
    <!-- 🌐 POV 1: TAMPILAN PELANGGAN (BOOKING ONLINE) -->
    <!-- ========================================== -->
    <main v-if="currentPOV === 'customer'" class="max-w-7xl mx-auto mt-6 px-4">
      
      <!-- Banner Sambutan -->
      <div class="bg-gradient-to-r from-emerald-800 to-teal-900 rounded-2xl p-6 text-white shadow-lg mb-6 flex flex-col md:flex-row items-center justify-between gap-4">
        <div class="flex items-center gap-4">
          <img src="/logo-jabal.png" alt="Jabal Outdoor" class="hidden sm:block w-20 h-20 rounded-xl object-cover border border-emerald-500/50 shadow-lg" />
          <div>
          <span class="bg-emerald-600/60 text-emerald-100 text-xs font-semibold px-3 py-1 rounded-full uppercase tracking-wider">Sewa Alat Camping Online</span>
          <h2 class="text-2xl md:text-3xl font-black mt-2">Rental Peralatan Outdoor Cepat & Praktis!</h2>
          <p class="text-xs text-emerald-200 mt-1 max-w-lg">Pilih peralatan camping favoritmu, tentukan tanggal sewa, dan lakukan booking secara langsung dari rumah.</p>
          </div>
        </div>
        <a href="#katalog" class="bg-white text-emerald-900 font-bold px-5 py-2.5 rounded-xl text-xs shadow hover:bg-emerald-50 transition">
          🛒 Lihat Katalog Peralatan
        </a>
      </div>

      <div id="katalog" class="space-y-8">
        
        <!-- Katalog Alat Camping -->
        <div class="space-y-4">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2 bg-white p-4 rounded-xl border">
            <h3 class="font-bold text-slate-800 text-sm flex items-center gap-1.5">
              <span>⛺</span> Katalog Peralatan Camping
            </h3>
            <div class="flex gap-2">
              <input v-model="searchProduct" type="text" placeholder="🔍 Cari tenda, bag..." class="border rounded-lg px-3 py-1.5 text-xs outline-none focus:ring-2 focus:ring-emerald-500" />
              <select v-model="selectedCategoryFilter" class="border rounded-lg px-2 py-1.5 text-xs">
                <option value="">Semua Kategori</option>
                <option value="Tenda">Tenda</option>
                <option value="Carrier/Tas">Carrier / Tas</option>
                <option value="Masak">Alat Masak</option>
                <option value="Sleeping Gear">Sleeping Gear</option>
                <option value="Lampu/Elektronik">Lampu / Elektronik</option>
              </select>
            </div>
          </div>

          <div v-if="filteredProducts.length === 0" class="bg-white p-8 text-center text-slate-400 text-xs rounded-xl border">
            Alat camping tidak ditemukan.
          </div>

          <div class="grid grid-cols-2 sm:grid-cols-3 gap-4">
            <div v-for="item in filteredProducts" :key="item.id" class="bg-white rounded-xl shadow-sm border border-slate-200 p-3 flex flex-col justify-between hover:shadow-md transition">
              <div>
                <img :src="item.image_url || 'https://via.placeholder.com/150'" class="w-full h-32 object-cover rounded-lg mb-2 bg-slate-50" />
                <span class="text-[10px] font-semibold bg-emerald-50 text-emerald-700 px-2 py-0.5 rounded">{{ item.category }}</span>
                <h4 class="font-bold text-slate-800 text-sm mt-1 leading-snug">{{ item.name }}</h4>
                <p class="text-xs text-slate-500 mt-1">Rp {{ Number(item.price_per_day).toLocaleString('id-ID') }} <span class="text-[10px]">/hari</span></p>
              </div>
              <div class="mt-3 pt-2 border-t space-y-2">
                <button @click="showProductDetails(item)" class="w-full text-emerald-700 hover:text-emerald-900 text-[11px] font-bold text-left cursor-pointer">
                  Lihat detail & spesifikasi →
                </button>
                <div class="flex justify-between items-center">
                <span :class="item.total_stock > 0 ? 'text-emerald-700' : 'text-red-500'" class="text-[11px] font-bold">
                  {{ item.total_stock > 0 ? `Stok: ${item.total_stock}` : 'Stok Habis' }}
                </span>
                <button @click="addToCart(item)" :disabled="item.total_stock <= 0" class="bg-emerald-700 hover:bg-emerald-800 disabled:bg-slate-300 text-white text-xs px-3 py-1.5 rounded-lg font-bold transition cursor-pointer">
                  + Sewa
                </button>
                </div>
              </div>
            </div>
          </div>
        </div>

      </div>
    </main>

    <!-- KERANJANG STICKY DAN CHECKOUT PELANGGAN -->
    <div v-if="currentPOV === 'customer' && cart.length > 0" class="fixed bottom-0 inset-x-0 z-40 bg-white/95 backdrop-blur border-t border-slate-200 shadow-[0_-4px_16px_rgba(15,23,42,0.12)] print:hidden">
      <div class="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between gap-4">
        <div class="min-w-0">
          <p class="text-xs text-slate-500">Keranjang sewa</p>
          <p class="font-black text-slate-800 text-sm truncate">{{ cartItemCount }} barang <span class="text-emerald-700">· Rp {{ totalPrice.toLocaleString('id-ID') }}</span></p>
        </div>
        <button @click="checkoutModalOpen = true" class="shrink-0 bg-emerald-700 hover:bg-emerald-800 text-white font-bold text-xs px-4 py-2.5 rounded-lg shadow cursor-pointer">
          Lanjut Checkout
        </button>
      </div>
    </div>

    <div v-if="checkoutModalOpen && cart.length > 0" class="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm flex items-end sm:items-center justify-center p-0 sm:p-4" @click.self="checkoutModalOpen = false">
      <div class="bg-white w-full sm:max-w-lg sm:rounded-2xl rounded-t-2xl shadow-2xl max-h-[92vh] overflow-y-auto">
        <div class="sticky top-0 bg-white border-b p-4 flex items-center justify-between z-10">
          <div>
            <h3 class="font-bold text-slate-800">Checkout & Kirim Booking Sewa</h3>
            <p class="text-[11px] text-slate-500">{{ cartItemCount }} barang dalam keranjang</p>
          </div>
          <button @click="checkoutModalOpen = false" aria-label="Tutup checkout" class="text-2xl text-slate-400 hover:text-slate-700 cursor-pointer">×</button>
        </div>

        <div class="p-5 space-y-4">
          <div class="space-y-2 max-h-36 overflow-y-auto pr-1">
            <div v-for="item in cart" :key="item.id" class="flex items-center justify-between text-xs bg-slate-50 p-2 rounded-lg">
              <div>
                <p class="font-bold text-slate-800">{{ item.name }}</p>
                <p class="text-slate-500">Rp {{ Number(item.price_per_day).toLocaleString('id-ID') }} / hari</p>
              </div>
              <div class="flex items-center gap-2">
                <button @click="updateQty(item.id, -1)" class="w-6 h-6 bg-slate-200 rounded font-bold cursor-pointer">-</button>
                <span class="font-bold text-slate-800">{{ item.qty }}</span>
                <button @click="updateQty(item.id, 1)" class="w-6 h-6 bg-slate-200 rounded font-bold cursor-pointer">+</button>
              </div>
            </div>
          </div>

          <div class="space-y-3 border-t pt-3">
            <div>
              <label class="block text-xs font-semibold text-slate-600 mb-1">Nama Lengkap Penyewa *</label>
              <input v-model="customerName" type="text" placeholder="Contoh: Andi Wijaya" class="w-full border rounded-lg p-2 text-xs" />
            </div>
            <div>
              <label class="block text-xs font-semibold text-slate-600 mb-1">No. WhatsApp Aktif *</label>
              <input v-model="customerPhone" type="text" placeholder="08123456789" class="w-full border rounded-lg p-2 text-xs" />
            </div>
            <div class="grid grid-cols-2 gap-2">
              <div>
                <label class="block text-xs font-semibold text-slate-600 mb-1">Tgl Ambil *</label>
                <input v-model="startDate" type="date" :min="today" class="w-full border rounded-lg p-1.5 text-xs" />
              </div>
              <div>
                <label class="block text-xs font-semibold text-slate-600 mb-1">Tgl Kembali *</label>
                <input v-model="endDate" type="date" :min="minimumEndDate" class="w-full border rounded-lg p-1.5 text-xs" />
              </div>
            </div>

            <div class="space-y-2">
              <label class="block text-xs font-semibold text-slate-600">Metode Pengambilan *</label>
              <div class="grid grid-cols-2 gap-2">
                <button @click="selectFulfillmentMethod('Ambil di Toko')" :class="fulfillmentMethod === 'Ambil di Toko' ? 'bg-emerald-700 text-white' : 'bg-slate-100 text-slate-700'" class="py-2 rounded-lg text-[11px] font-bold cursor-pointer">Ambil di Toko</button>
                <button @click="selectFulfillmentMethod('Antar')" :class="fulfillmentMethod === 'Antar' ? 'bg-emerald-700 text-white' : 'bg-slate-100 text-slate-700'" class="py-2 rounded-lg text-[11px] font-bold cursor-pointer">Antar ke Alamat</button>
              </div>
              <textarea v-if="fulfillmentMethod === 'Antar'" v-model="deliveryAddress" rows="3" placeholder="Tulis alamat lengkap pengantaran..." class="w-full border rounded-lg p-2 text-xs"></textarea>
              <p v-if="fulfillmentMethod === 'Antar'" class="text-[10px] text-amber-700 bg-amber-50 border border-amber-200 rounded-lg p-2">Biaya pengantaran GoSend belum termasuk total sewa. Estimasi biaya akan dikonfirmasi melalui WhatsApp.</p>
            </div>
          </div>

          <div class="pt-2 border-t space-y-2">
            <label class="block text-xs font-bold text-slate-700">Metode Pembayaran</label>
            <div class="grid grid-cols-3 gap-1.5">
              <button @click="selectPaymentMethod('QRIS')" :class="paymentMethod === 'QRIS' ? 'bg-emerald-700 text-white' : 'bg-slate-100 text-slate-700'" class="py-2 rounded-lg text-[11px] font-bold cursor-pointer">📱 QRIS</button>
              <button @click="selectPaymentMethod('Transfer Bank')" :class="paymentMethod === 'Transfer Bank' ? 'bg-emerald-700 text-white' : 'bg-slate-100 text-slate-700'" class="py-2 rounded-lg text-[11px] font-bold cursor-pointer">🏦 Transfer</button>
              <button @click="selectPaymentMethod('Tunai')" :class="paymentMethod === 'Tunai' ? 'bg-emerald-700 text-white' : 'bg-slate-100 text-slate-700'" class="py-2 rounded-lg text-[11px] font-bold cursor-pointer">💵 Tunai</button>
            </div>

            <div v-if="paymentMethod === 'QRIS'" class="bg-emerald-50 p-3 rounded-lg border border-emerald-200 text-[11px] space-y-2 text-center">
              <p class="font-bold">Scan QRIS, lalu upload bukti pembayaran</p>
              <img src="/qris-jabal.png" alt="QRIS pembayaran Jabal Outdoor" class="w-44 h-44 object-contain mx-auto bg-white rounded-lg border" />
              <label class="block text-left font-semibold text-slate-600">Bukti pembayaran QRIS *</label>
              <input type="file" accept="image/*" @change="handleProofChange" required class="w-full text-xs border rounded-lg p-1.5 bg-white text-left" />
            </div>
            <div v-else-if="paymentMethod === 'Transfer Bank'" class="bg-emerald-50 p-2.5 rounded-lg border border-emerald-200 text-[11px] text-emerald-900 space-y-1">
              <p class="font-bold">Pembayaran Bisa Melalui:</p>
              <p><b>BSI:</b> 1045152761 a.n. Mahmud Rosyad Al Farizi</p>
              <p><b>SeaBank:</b> 901389650069 a.n. Mahmud Rosyad Al Farizi</p>
              <p><b>DANA & ShopeePay:</b> 089517829189 a.n. Mahmud Rosyad Al Farizi</p>
              <p>Silakan transfer sesuai total pembayaran.</p>
              <label class="block font-semibold text-slate-600 pt-1">Bukti transfer (opsional)</label>
              <input type="file" accept="image/*" @change="handleProofChange" class="w-full text-xs border rounded-lg p-1.5 bg-white" />
            </div>
            <div v-else class="bg-slate-50 p-2.5 rounded-lg border text-[11px] text-slate-600">Bayar tunai saat mengambil alat di toko.</div>
          </div>

          <div class="bg-slate-50 p-3 rounded-lg text-slate-800 space-y-1 text-xs border">
            <div class="flex justify-between"><span>Durasi Sewa:</span><span class="font-bold">{{ totalDays }} Hari</span></div>
            <div class="flex justify-between text-sm pt-1 border-t"><span class="font-bold">Total Estimasi:</span><span class="font-black text-emerald-700">Rp {{ totalPrice.toLocaleString('id-ID') }}</span></div>
          </div>

          <button @click="processCheckout(true)" class="w-full bg-emerald-700 hover:bg-emerald-800 text-white font-bold py-2.5 rounded-lg text-xs transition shadow cursor-pointer">🚀 Kirim Booking Sewa</button>
        </div>
      </div>
    </div>

    <!-- MODAL DETAIL PRODUK -->
    <div v-if="selectedProduct" class="fixed inset-0 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4 z-50" @click.self="closeProductDetails">
      <div class="bg-white rounded-2xl shadow-2xl max-w-lg w-full max-h-[90vh] overflow-y-auto"> 
        <img :src="selectedProduct.image_url || 'https://via.placeholder.com/600x360'" :alt="selectedProduct.name" class="w-full h-56 object-cover rounded-t-2xl bg-slate-100" />
        <div class="p-6 space-y-4">
          <div class="flex items-start justify-between gap-4">
            <div>
              <span class="text-[10px] font-semibold bg-emerald-50 text-emerald-700 px-2 py-0.5 rounded">{{ selectedProduct.category }}</span>
              <h3 class="text-xl font-black text-slate-800 mt-2">{{ selectedProduct.name }}</h3>
              <p class="text-sm text-emerald-700 font-bold mt-1">Rp {{ Number(selectedProduct.price_per_day).toLocaleString('id-ID') }} / hari</p>
            </div>
            <button @click="closeProductDetails" aria-label="Tutup detail produk" class="text-2xl text-slate-400 hover:text-slate-700 cursor-pointer">×</button>
          </div>
          <div class="border-t pt-4 space-y-3 text-sm text-slate-600">
            <div>
              <h4 class="font-bold text-slate-800">Deskripsi</h4>
              <p class="mt-1 whitespace-pre-line">{{ selectedProduct.description || 'Peralatan outdoor berkualitas untuk menemani aktivitas camping kamu.' }}</p>
            </div>
            <div>
              <h4 class="font-bold text-slate-800">Spesifikasi & kelengkapan</h4>
              <p class="mt-1 whitespace-pre-line">{{ selectedProduct.specifications || selectedProduct.specification || 'Spesifikasi belum ditambahkan oleh admin.' }}</p>
            </div>
            <p><b>Ketersediaan:</b> {{ selectedProduct.total_stock > 0 ? `${selectedProduct.total_stock} unit` : 'Stok habis' }}</p>
          </div>
          <button @click="addToCart(selectedProduct); closeProductDetails()" :disabled="selectedProduct.total_stock <= 0" class="w-full bg-emerald-700 hover:bg-emerald-800 disabled:bg-slate-300 text-white font-bold py-2.5 rounded-xl text-xs cursor-pointer">
            + Tambahkan ke keranjang
          </button>
        </div>
      </div>
    </div>

    <!-- ========================================== -->
    <!-- 🔒 LOGIN ADMIN / KASIR POPUP -->
    <!-- ========================================== -->
    <div v-if="currentPOV === 'admin_login' && !isAdminLoggedIn" class="fixed inset-0 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4 z-50">
      <div class="bg-white rounded-2xl shadow-2xl max-w-sm w-full p-6 text-center space-y-4">
        <div class="w-12 h-12 bg-emerald-100 text-emerald-800 rounded-full flex items-center justify-center mx-auto text-2xl">🔒</div>
        <div>
          <h3 class="text-lg font-bold text-slate-800">Akses Dashboard Admin</h3>
          <p class="text-xs text-slate-500 mt-1">Masukkan PIN Keamanan Admin/Kasir</p>
        </div>

        <div>
          <input v-model="pinInput" type="password" maxlength="6" placeholder="Masukkan PIN (Default: 1234)" @keyup.enter="loginAdmin" class="w-full border-2 rounded-xl p-2.5 text-center text-lg font-bold tracking-widest outline-none focus:border-emerald-600" />
          <p v-if="pinError" class="text-xs text-red-600 font-semibold mt-1">PIN salah! Silakan coba lagi.</p>
        </div>

        <div class="flex gap-2">
          <button @click="loginAdmin" class="flex-1 bg-emerald-700 text-white font-bold py-2.5 rounded-xl text-xs">Masuk Admin</button>
          <button @click="closeAdminLogin" class="bg-slate-200 text-slate-700 font-semibold px-4 py-2.5 rounded-xl text-xs">Batal</button>
        </div>
      </div>
    </div>

    <!-- ========================================== -->
    <!-- 🏢 POV 2: DASHBOARD ADMIN / KASIR (POS) -->
    <!-- ========================================== -->
    <div v-if="currentPOV === 'admin' && isAdminLoggedIn">
      
      <!-- Sub-Header Admin Navigation -->
      <nav class="bg-emerald-800 text-white p-3 shadow-sm print:hidden">
        <div class="max-w-7xl mx-auto flex flex-col md:flex-row justify-between items-center gap-2">
          <div class="flex items-center gap-2">
            <img src="/logo-jabal.png" alt="Logo Jabal Outdoor" class="w-9 h-9 rounded-md object-cover border border-emerald-600" />
            <h2 class="font-bold text-sm">Dashboard Admin Kasir</h2>
          </div>
          <div class="flex bg-emerald-900/60 p-1 rounded-lg border border-emerald-700 space-x-1 text-xs">
            <button @click="activeTab = 'pos'" :class="activeTab === 'pos' ? 'bg-emerald-600 font-bold' : 'text-emerald-200'" class="px-3 py-1.5 rounded-md cursor-pointer">
              🛒 Kasir Toko
            </button>
            <button @click="activeTab = 'online_orders'" :class="activeTab === 'online_orders' ? 'bg-emerald-600 font-bold' : 'text-emerald-200'" class="px-3 py-1.5 rounded-md cursor-pointer flex items-center gap-1">
              📥 Booking Online
              <span v-if="stats.pendingCount > 0" class="bg-amber-400 text-slate-900 font-black text-[10px] px-1.5 rounded-full">{{ stats.pendingCount }}</span>
            </button>
            <button @click="activeTab = 'orders'" :class="activeTab === 'orders' ? 'bg-emerald-600 font-bold' : 'text-emerald-200'" class="px-3 py-1.5 rounded-md cursor-pointer flex items-center gap-1">
              📜 Riwayat Sewa
              <span v-if="stats.overdueOrdersCount > 0" class="bg-red-500 text-white font-bold text-[10px] px-1.5 rounded-full">{{ stats.overdueOrdersCount }}</span>
            </button>
            <button @click="activeTab = 'reports'" :class="activeTab === 'reports' ? 'bg-emerald-600 font-bold' : 'text-emerald-200'" class="px-3 py-1.5 rounded-md cursor-pointer">
              📊 Laporan Keuangan
            </button>
            <button @click="activeTab = 'inventory'" :class="activeTab === 'inventory' ? 'bg-emerald-600 font-bold' : 'text-emerald-200'" class="px-3 py-1.5 rounded-md cursor-pointer">
              📦 Stok Inventaris
            </button>
          </div>
        </div>
      </nav>

      <main class="max-w-7xl mx-auto mt-6 px-4 print:hidden">
        
        <!-- TAB ADMIN 1: KASIR TRANSAKSI OFFLINE -->
        <div v-if="activeTab === 'pos'" class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div class="lg:col-span-2 space-y-4">
            <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
              <h3 class="font-bold text-slate-800 text-base">🛒 Kasir Toko (Pilih Barang)</h3>
              <div class="flex gap-2">
                <input v-model="searchProduct" type="text" placeholder="🔍 Cari barang..." class="bg-white border rounded-lg px-3 py-1.5 text-xs outline-none" />
                <select v-model="selectedCategoryFilter" class="bg-white border rounded-lg px-2 py-1.5 text-xs">
                  <option value="">Semua Kategori</option>
                  <option value="Tenda">Tenda</option>
                  <option value="Carrier/Tas">Carrier / Tas</option>
                  <option value="Masak">Alat Masak</option>
                  <option value="Sleeping Gear">Sleeping Gear</option>
                  <option value="Lampu/Elektronik">Lampu / Elektronik</option>
                </select>
              </div>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
              <div v-for="item in filteredProducts" :key="item.id" class="bg-white rounded-xl shadow-sm border p-3 flex flex-col justify-between">
                <div>
                  <img :src="item.image_url || 'https://via.placeholder.com/150'" class="w-full h-28 object-cover rounded-lg mb-2 bg-slate-50" />
                  <span class="text-[10px] font-semibold bg-emerald-50 text-emerald-700 px-2 py-0.5 rounded">{{ item.category }}</span>
                  <h4 class="font-bold text-slate-800 text-sm mt-1 leading-snug">{{ item.name }}</h4>
                  <p class="text-xs text-slate-500 mt-1">Rp {{ Number(item.price_per_day).toLocaleString('id-ID') }} /hari</p>
                </div>
                <div class="mt-3 flex justify-between items-center pt-2 border-t">
                  <span class="text-xs font-medium text-slate-600">Stok: <b>{{ item.total_stock }}</b></span>
                  <button @click="addToCart(item)" :disabled="item.total_stock <= 0" class="bg-emerald-700 hover:bg-emerald-800 disabled:bg-slate-300 text-white text-xs px-3 py-1.5 rounded-lg font-bold cursor-pointer">
                    + Sewa
                  </button>
                </div>
              </div>
            </div>
          </div>

          <!-- Form Checkout Kasir -->
          <div class="bg-white p-5 rounded-xl shadow-sm border space-y-4 h-fit">
            <h3 class="text-base font-bold text-slate-800 border-b pb-2">🧾 Transaksi Kasir</h3>
            
            <div v-if="cart.length === 0" class="text-center py-6 text-slate-400 text-xs">Keranjang transaksi kosong</div>
            <div v-else class="space-y-2 max-h-40 overflow-y-auto pr-1">
              <div v-for="item in cart" :key="item.id" class="flex items-center justify-between text-xs bg-slate-50 p-2 rounded-lg">
                <div>
                  <p class="font-bold text-slate-800">{{ item.name }}</p>
                  <p class="text-slate-500">Rp {{ Number(item.price_per_day).toLocaleString('id-ID') }} / hr</p>
                </div>
                <div class="flex items-center space-x-2">
                  <button @click="updateQty(item.id, -1)" class="w-5 h-5 bg-slate-200 rounded font-bold">-</button>
                  <span class="font-bold text-slate-800">{{ item.qty }}</span>
                  <button @click="updateQty(item.id, 1)" class="w-5 h-5 bg-slate-200 rounded font-bold">+</button>
                </div>
              </div>
            </div>

            <div class="space-y-3 pt-2 border-t">
              <input v-model="customerName" type="text" placeholder="Nama Pelanggan" class="w-full border rounded-lg p-2 text-xs" />
              <input v-model="customerPhone" type="text" placeholder="No. WhatsApp" class="w-full border rounded-lg p-2 text-xs" />
              <div class="grid grid-cols-2 gap-2">
                <input v-model="startDate" type="date" class="w-full border rounded-lg p-1.5 text-xs" />
                <input v-model="endDate" type="date" class="w-full border rounded-lg p-1.5 text-xs" />
              </div>

              <!-- Pembayaran Kasir -->
              <div class="space-y-2 pt-1">
                <label class="block text-xs font-bold text-slate-700">Metode Bayar Kasir</label>
                <div class="grid grid-cols-3 gap-1">
                  <button @click="paymentMethod = 'Tunai'" :class="paymentMethod === 'Tunai' ? 'bg-emerald-700 text-white' : 'bg-slate-100'" class="py-1 text-xs rounded-lg font-semibold">💵 Tunai</button>
                  <button @click="paymentMethod = 'Transfer Bank'" :class="paymentMethod === 'Transfer Bank' ? 'bg-emerald-700 text-white' : 'bg-slate-100'" class="py-1 text-xs rounded-lg font-semibold">🏦 Transfer</button>
                  <button @click="paymentMethod = 'QRIS'" :class="paymentMethod === 'QRIS' ? 'bg-emerald-700 text-white' : 'bg-slate-100'" class="py-1 text-xs rounded-lg font-semibold">📱 QRIS</button>
                </div>

                <div v-if="paymentMethod === 'Tunai'" class="space-y-1 pt-1">
                  <input v-model="amountPaid" type="number" placeholder="Nominal Diterima (Rp)" class="w-full border rounded-lg p-2 text-xs font-bold" />
                  <div class="flex justify-between bg-slate-100 p-2 rounded-lg text-xs">
                    <span>Kembalian:</span>
                    <span class="font-bold text-slate-800">Rp {{ changeAmount.toLocaleString('id-ID') }}</span>
                  </div>
                </div>
                <div v-else-if="paymentMethod === 'Transfer Bank'" class="bg-emerald-50 p-2.5 rounded-lg border border-emerald-200 text-[11px] text-emerald-900 space-y-1">
                  <p class="font-bold">Pembayaran Bisa Melalui:</p>
                  <p><b>BSI:</b> 1045152761 a.n. Mahmud Rosyad Al Farizi</p>
                  <p><b>SeaBank:</b> 901389650069 a.n. Mahmud Rosyad Al Farizi</p>
                  <p><b>DANA & ShopeePay:</b> 089517829189 a.n. Mahmud Rosyad Al Farizi</p>
                </div>
              </div>
            </div>

            <div class="bg-emerald-50 p-3 rounded-lg text-emerald-900 text-xs flex justify-between font-bold">
              <span>Total Tagihan:</span>
              <span class="text-sm text-emerald-800">Rp {{ totalPrice.toLocaleString('id-ID') }}</span>
            </div>

            <button @click="processCheckout(false)" class="w-full bg-emerald-700 hover:bg-emerald-800 text-white font-bold py-2.5 rounded-lg text-xs shadow cursor-pointer">
              Cetak Struk & Simpan Transaksi
            </button>
          </div>
        </div>

        <!-- TAB ADMIN 2: BOOKING ONLINE MASUK (APPROVAL) -->
        <div v-if="activeTab === 'online_orders'" class="bg-white p-6 rounded-xl shadow-sm border space-y-4">
          <div class="flex justify-between items-center border-b pb-3">
            <div>
              <h3 class="text-base font-bold text-slate-800 flex items-center gap-2">
                <span>📥</span> Booking Online Menunggu Konfirmasi
              </h3>
              <p class="text-xs text-slate-500">Konfirmasi reservasi pelanggan yang masuk dari website</p>
            </div>
            <button @click="fetchOrders" class="text-xs bg-slate-100 hover:bg-slate-200 px-3 py-1 rounded-md border">🔄 Refresh Data</button>
          </div>

          <div v-if="pendingOnlineOrders.length === 0" class="text-center py-10 text-slate-400 text-sm">
            Belum ada booking online baru yang masuk.
          </div>

          <div v-else class="space-y-4">
            <div v-for="order in pendingOnlineOrders" :key="order.id" class="border rounded-xl p-4 bg-slate-50 flex flex-col md:flex-row justify-between gap-4">
              <div class="space-y-2 text-xs flex-1">
                <div class="flex items-center gap-2">
                  <span class="bg-amber-100 text-amber-800 font-bold px-2 py-0.5 rounded text-[10px]">Menunggu Approval</span>
                  <span class="text-slate-400">ID: #{{ order.id }}</span>
                </div>
                <h4 class="font-bold text-sm text-slate-800">{{ order.customer_name }} ({{ order.customer_phone }})</h4>
                <p class="text-slate-600">🗓️ Periode: <b>{{ order.start_date }} s/d {{ order.end_date }}</b> ({{ order.total_days }} Hari)</p>
                
                <div class="bg-white p-2.5 rounded-lg border space-y-1">
                  <p class="font-bold text-slate-700">Daftar Alat Dibooking:</p>
                  <div v-for="item in order.order_items" :key="item.id" class="flex justify-between text-slate-600">
                    <span>- {{ item.product_name }} x{{ item.quantity }}</span>
                    <span>Rp {{ Number(item.subtotal).toLocaleString('id-ID') }}</span>
                  </div>
                </div>

                <div class="bg-emerald-50 p-2.5 rounded-lg border border-emerald-100 space-y-1 text-slate-700">
                  <p><b>Metode Pembayaran:</b> {{ order.payment_method || '-' }}</p>
                  <p><b>Pengambilan:</b> {{ order.fulfillment_method || 'Ambil di Toko' }}</p>
                  <p v-if="order.fulfillment_method === 'Antar'" class="break-words"><b>Alamat Antar:</b> {{ order.delivery_address || '-' }}</p>
                  <p v-if="order.fulfillment_method === 'Antar'" class="text-amber-700"><b>Catatan:</b> Estimasi biaya GoSend belum termasuk dan akan dikonfirmasi melalui WhatsApp.</p>
                </div>

                <div class="bg-white p-2.5 rounded-lg border space-y-1 text-slate-700">
                  <div class="flex justify-between"><span>Subtotal Sewa:</span><span>Rp {{ Number(order.total_price || 0).toLocaleString('id-ID') }}</span></div>
                  <div v-if="Number(order.late_fee || 0) > 0" class="flex justify-between"><span>Denda Keterlambatan:</span><span>Rp {{ Number(order.late_fee).toLocaleString('id-ID') }}</span></div>
                  <div v-if="Number(order.damage_fee || 0) > 0" class="flex justify-between"><span>Denda Kerusakan/Hilang:</span><span>Rp {{ Number(order.damage_fee).toLocaleString('id-ID') }}</span></div>
                  <div class="flex justify-between border-t pt-1 text-sm font-black text-emerald-800">
                    <span>Total Akhir:</span>
                    <span>Rp {{ (Number(order.total_price || 0) + Number(order.late_fee || 0) + Number(order.damage_fee || 0)).toLocaleString('id-ID') }}</span>
                  </div>
                </div>
              </div>

              <!-- Bukti Transfer & Aksi -->
              <div class="w-full md:w-56 space-y-2 flex flex-col justify-between border-t md:border-t-0 md:border-l pt-3 md:pt-0 md:pl-4">
                <div>
                  <p class="text-xs font-bold text-slate-700 mb-1">Bukti Pembayaran:</p>
                  <a v-if="order.proof_of_payment" :href="order.proof_of_payment" target="_blank" class="block text-center bg-blue-50 text-blue-700 border border-blue-200 rounded-lg p-2 text-xs font-semibold hover:underline">
                    🖼️ Lihat Foto Bukti
                  </a>
                  <span v-else class="text-xs text-slate-400 italic block">Tidak ada lampiran foto</span>
                </div>

                <div class="space-y-1.5 pt-2">
                  <button @click="approveOnlineOrder(order)" class="w-full bg-emerald-700 hover:bg-emerald-800 text-white font-bold py-2 rounded-lg text-xs cursor-pointer">
                    ✅ Setujui & Potong Stok
                  </button>
                  <button @click="rejectOnlineOrder(order)" class="w-full bg-red-100 hover:bg-red-200 text-red-700 font-bold py-1.5 rounded-lg text-xs cursor-pointer">
                    ❌ Tolak Booking
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- TAB ADMIN 3: RIWAYAT SEWA -->
        <div v-if="activeTab === 'orders'" class="bg-white p-6 rounded-xl shadow-sm border space-y-4">
          <div class="flex flex-col md:flex-row justify-between items-md-center gap-3 border-b pb-3">
            <h3 class="font-bold text-slate-800 text-base">📜 Semua Riwayat Transaksi</h3>
            <div class="flex flex-wrap gap-2">
              <input v-model="searchOrder" type="text" placeholder="🔍 Cari Nama / No HP..." class="border rounded-lg px-3 py-1 text-xs outline-none" />
              <select v-model="statusOrderFilter" class="border rounded-lg px-2 py-1 text-xs">
                <option value="">Semua Status</option>
                <option value="Aktif">Sedang Sewa (Aktif)</option>
                <option value="Pending">Menunggu Approval</option>
                <option value="Terlambat">🚨 Terlambat</option>
                <option value="Selesai">Selesai</option>
              </select>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="w-full text-left text-sm border-collapse">
              <thead>
                <tr class="bg-slate-50 border-b text-slate-600 text-xs uppercase">
                  <th class="p-3">Penyewa</th>
                  <th class="p-3">Tipe & Periode</th>
                  <th class="p-3 text-center">Tenggat</th>
                  <th class="p-3">Total</th>
                  <th class="p-3 text-center">Status</th>
                  <th class="p-3 text-center">Aksi</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-100">
                <tr v-for="item in filteredOrders" :key="item.id" class="hover:bg-slate-50">
                  <td class="p-3 font-semibold text-slate-800">
                    {{ item.customer_name }}
                    <span class="block text-xs font-normal text-slate-500">{{ item.customer_phone }}</span>
                  </td>
                  <td class="p-3 text-xs text-slate-600">
                    <span :class="item.order_type === 'online' ? 'bg-blue-100 text-blue-800' : 'bg-slate-100 text-slate-700'" class="text-[10px] font-bold px-1.5 py-0.5 rounded uppercase mr-1">
                      {{ item.order_type || 'offline' }}
                    </span>
                    {{ item.start_date }} s/d {{ item.end_date }}
                  </td>
                  <td class="p-3 text-center">
                    <span :class="getDueDateStatus(item).color" class="text-[11px] px-2 py-0.5 rounded-full border">
                      {{ getDueDateStatus(item).label }}
                    </span>
                  </td>
                  <td class="p-3 font-bold text-emerald-700">
                    Rp {{ (Number(item.total_price) + Number(item.late_fee || 0) + Number(item.damage_fee || 0)).toLocaleString('id-ID') }}
                  </td>
                  <td class="p-3 text-center">
                    <span :class="item.status === 'Aktif' ? 'bg-amber-100 text-amber-800' : (item.status === 'Selesai' ? 'bg-emerald-100 text-emerald-800' : 'bg-slate-200')" class="text-[11px] font-bold px-2.5 py-1 rounded-full">
                      {{ item.status }}
                    </span>
                  </td>
                  <td class="p-3 text-center space-x-1 space-y-1">
                    <button v-if="item.status === 'Aktif'" @click="sendReminderWhatsApp(item)" title="Kirim Pengingat WA" class="text-xs bg-emerald-600 text-white px-2 py-1 rounded">
                      📲 Ingatkan WA
                    </button>
                    <button @click="receiptModalData = item" class="text-xs bg-slate-100 text-slate-700 px-2 py-1 rounded border">
                      🧾 Struk
                    </button>
                    <button v-if="item.status === 'Aktif'" @click="openReturnModal(item)" class="text-xs bg-amber-600 text-white px-2 py-1 rounded">
                      Kembalikan
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <!-- TAB ADMIN 4: LAPORAN KEUANGAN -->
        <div v-if="activeTab === 'reports'" class="space-y-6">
          <div class="flex flex-col sm:flex-row justify-between bg-white p-4 rounded-xl border shadow-sm gap-3">
            <div>
              <h3 class="font-bold text-slate-800">📊 Ekspor Laporan Keuangan</h3>
              <p class="text-xs text-slate-500">Unduh data transaksi dalam format Excel atau PDF</p>
            </div>
            <div class="flex gap-2">
              <button @click="exportToExcel" class="bg-emerald-700 text-white font-semibold text-xs px-4 py-2 rounded-lg cursor-pointer">📊 Excel (.xlsx)</button>
              <button @click="exportToPDF" class="bg-red-700 text-white font-semibold text-xs px-4 py-2 rounded-lg cursor-pointer">📄 PDF</button>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <div class="bg-white p-5 rounded-xl border shadow-sm">
              <p class="text-xs text-slate-500 font-bold uppercase">Pemasukan Hari Ini</p>
              <p class="text-2xl font-black text-emerald-700 mt-1">Rp {{ stats.totalIncomeToday.toLocaleString('id-ID') }}</p>
            </div>
            <div class="bg-white p-5 rounded-xl border shadow-sm">
              <p class="text-xs text-slate-500 font-bold uppercase">Pemasukan Bulan Ini</p>
              <p class="text-2xl font-black text-emerald-700 mt-1">Rp {{ stats.totalIncomeMonth.toLocaleString('id-ID') }}</p>
            </div>
            <div class="bg-white p-5 rounded-xl border shadow-sm">
              <p class="text-xs text-slate-500 font-bold uppercase">Total Keseluruhan</p>
              <p class="text-2xl font-black text-slate-800 mt-1">Rp {{ stats.totalIncomeAll.toLocaleString('id-ID') }}</p>
            </div>
            <div class="bg-white p-5 rounded-xl border shadow-sm">
              <p class="text-xs text-slate-500 font-bold uppercase">Sewa Aktif</p>
              <p class="text-2xl font-black text-amber-600 mt-1">{{ stats.activeOrdersCount }} Sewa</p>
            </div>
          </div>
        </div>

        <!-- TAB ADMIN 5: KELOLA STOK INVENTARIS -->
        <div v-if="activeTab === 'inventory'" class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <section class="bg-white p-6 rounded-xl border h-fit space-y-4">
            <h3 class="font-bold text-slate-800 text-base">{{ isEditing ? '✏️ Edit Barang' : '➕ Tambah Barang' }}</h3>
            <form @submit.prevent="saveProduct" class="space-y-3">
              <input v-model="newProduct.name" type="text" placeholder="Nama Peralatan" class="w-full border rounded-lg p-2 text-xs" required />
              <select v-model="newProduct.category" class="w-full border rounded-lg p-2 text-xs">
                <option value="Tenda">Tenda</option>
                <option value="Carrier/Tas">Carrier / Tas</option>
                <option value="Masak">Alat Masak / Kompor</option>
                <option value="Sleeping Gear">Sleeping Bag / Matras</option>
                <option value="Lampu/Elektronik">Lampu / Elektronik</option>
              </select>
              <textarea v-model="newProduct.description" rows="3" placeholder="Deskripsi barang (contoh: tenda nyaman untuk 4 orang)" class="w-full border rounded-lg p-2 text-xs"></textarea>
              <textarea v-model="newProduct.specifications" rows="3" placeholder="Spesifikasi & kelengkapan (contoh: ukuran, kapasitas, isi paket)" class="w-full border rounded-lg p-2 text-xs"></textarea>
              <input type="file" accept="image/*" @change="handleFileChange" class="w-full text-xs border rounded-lg p-1.5" />
              <div class="grid grid-cols-2 gap-2">
                <input v-model="newProduct.price_per_day" type="number" placeholder="Harga/Hari" class="w-full border rounded-lg p-2 text-xs" required />
                <input v-model="newProduct.total_stock" type="number" placeholder="Stok" class="w-full border rounded-lg p-2 text-xs" required />
              </div>
              <div class="flex gap-2 pt-2">
                <button type="submit" :disabled="uploading" class="flex-1 bg-emerald-700 text-white font-bold py-2 rounded-lg text-xs">
                  {{ uploading ? 'Proses...' : (isEditing ? 'Perbarui' : 'Simpan') }}
                </button>
                <button v-if="isEditing" @click="resetForm" type="button" class="bg-slate-200 px-3 py-2 rounded-lg text-xs">Batal</button>
              </div>
            </form>
          </section>

          <section class="md:col-span-2 bg-white p-6 rounded-xl border">
            <h3 class="font-bold text-slate-800 text-base mb-4">📦 Kelola Stok Inventaris</h3>
            <div class="overflow-x-auto">
              <table class="w-full text-left text-sm">
                <thead>
                  <tr class="bg-slate-50 text-xs text-slate-600 border-b">
                    <th class="p-2">Foto</th>
                    <th class="p-2">Nama Barang</th>
                    <th class="p-2">Harga/Hari</th>
                    <th class="p-2 text-center">Stok</th>
                    <th class="p-2 text-center">Aksi</th>
                  </tr>
                </thead>
                <tbody class="divide-y">
                  <tr v-for="item in products" :key="item.id">
                    <td class="p-2"><img :src="item.image_url || 'https://via.placeholder.com/50'" class="w-10 h-10 object-cover rounded" /></td>
                    <td class="p-2 font-medium">{{ item.name }}</td>
                    <td class="p-2 text-emerald-700 font-semibold">Rp {{ Number(item.price_per_day).toLocaleString('id-ID') }}</td>
                    <td class="p-2 text-center font-bold">{{ item.total_stock }}</td>
                    <td class="p-2 text-center space-x-2">
                      <button @click="editProduct(item)" class="text-blue-600 text-xs font-semibold">Edit</button>
                      <button @click="deleteProduct(item.id, item.name)" class="text-red-600 text-xs font-semibold">Hapus</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>

      </main>
    </div>

    <!-- MODAL SUKSES BOOKING ONLINE (PELANGGAN) -->
    <div v-if="bookingSuccessModal" class="fixed inset-0 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4 z-50">
      <div class="bg-white rounded-2xl shadow-2xl max-w-sm w-full p-6 text-center space-y-4">
        <div class="w-16 h-16 bg-emerald-100 text-emerald-700 rounded-full flex items-center justify-center mx-auto text-3xl">🎉</div>
        <h3 class="text-lg font-bold text-slate-800">Booking Berhasil Dikirimpkan!</h3>
        <p class="text-xs text-slate-600">Terima kasih Kak <b>{{ lastBookingData?.customer_name }}</b>! Pesanan booking kamu sedang diproses oleh admin kami.</p>
        
        <div class="bg-slate-50 p-3 rounded-xl border text-xs text-left space-y-1">
          <p><b>ID Order:</b> #{{ lastBookingData?.id }}</p>
          <p><b>Total Tagihan:</b> Rp {{ Number(lastBookingData?.total_price).toLocaleString('id-ID') }}</p>
          <p><b>Status:</b> <span class="text-amber-600 font-bold">Menunggu Konfirmasi Admin</span></p>
        </div>

        <button @click="sendBookingConfirmationToAdmin(lastBookingData)" class="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-bold py-2.5 rounded-xl text-xs flex items-center justify-center gap-2 cursor-pointer">
          📲 Konfirmasi Langsung via WhatsApp Admin
        </button>
        <button @click="bookingSuccessModal = false" class="w-full bg-slate-100 text-slate-700 font-semibold py-2 rounded-xl text-xs">
          Tutup
        </button>
      </div>
    </div>

    <!-- MODAL PENGEMBALIAN & DENDA -->
    <div v-if="returnModalOrder" class="fixed inset-0 bg-slate-900/50 backdrop-blur-sm flex items-center justify-center p-4 z-50">
      <div class="bg-white rounded-xl shadow-2xl max-w-md w-full p-6 space-y-4">
        <h3 class="text-base font-bold text-slate-800 border-b pb-2">🔄 Form Pengembalian & Denda</h3>
        <p class="text-xs text-slate-600">Pelanggan: <b>{{ returnModalOrder.customer_name }}</b></p>
        
        <div class="space-y-3">
          <div>
            <label class="block text-xs font-semibold text-slate-600 mb-1">Terlambat (Hari)</label>
            <input v-model="lateDaysInput" type="number" min="0" class="w-full border rounded-lg p-2 text-xs" />
          </div>
          <div>
            <label class="block text-xs font-semibold text-slate-600 mb-1">Denda Kerusakan / Hilang (Rp)</label>
            <input v-model="damageFeeInput" type="number" min="0" class="w-full border rounded-lg p-2 text-xs" />
          </div>
          <div>
            <textarea v-model="returnNotesInput" placeholder="Catatan pengembalian..." class="w-full border rounded-lg p-2 text-xs h-16"></textarea>
          </div>
        </div>

        <div class="bg-slate-50 p-3 rounded-lg text-xs space-y-1">
          <div class="flex justify-between font-bold text-emerald-800">
            <span>TOTAL PEMBAYARAN AKHIR:</span>
            <span>Rp {{ (Number(returnModalOrder.total_price) + calculatedLateFee + Number(damageFeeInput || 0)).toLocaleString('id-ID') }}</span>
          </div>
        </div>

        <div class="flex gap-2">
          <button @click="submitReturn" class="flex-1 bg-emerald-700 text-white font-bold py-2 rounded-lg text-xs">Selesaikan & Simpan</button>
          <button @click="returnModalOrder = null" class="bg-slate-200 text-slate-700 font-semibold px-4 py-2 rounded-lg text-xs">Batal</button>
        </div>
      </div>
    </div>

    <!-- MODAL STRUK CETAK -->
    <div v-if="receiptModalData" class="fixed inset-0 bg-slate-900/50 backdrop-blur-sm flex items-center justify-center p-4 z-50">
      <div class="bg-white rounded-xl shadow-2xl max-w-sm w-full p-6 space-y-4 print:p-0 print:shadow-none">
        <div id="receipt-print-area" class="text-slate-800 space-y-3 font-mono text-xs">
          <div class="text-center border-b border-dashed pb-3">
            <h3 class="font-bold text-base text-emerald-800">JABAL OUTDOOR</h3>
            <p class="text-[10px] text-slate-500">Nota Transaksi Sewa</p>
          </div>
          <div class="space-y-1 text-[11px]">
            <div class="flex justify-between"><span>Penyewa:</span><b>{{ receiptModalData.customer_name }}</b></div>
            <div class="flex justify-between"><span>No. HP:</span><span>{{ receiptModalData.customer_phone }}</span></div>
            <div class="flex justify-between"><span>Periode:</span><span>{{ receiptModalData.start_date }} - {{ receiptModalData.end_date }}</span></div>
            <div class="flex justify-between"><span>Pengambilan:</span><span>{{ receiptModalData.fulfillment_method || 'Ambil di Toko' }}</span></div>
            <div v-if="receiptModalData.fulfillment_method === 'Antar'" class="text-left"><span>Alamat:</span> {{ receiptModalData.delivery_address || '-' }}</div>
          </div>
          <div class="border-t border-b border-dashed py-2 space-y-1">
            <div v-for="item in receiptModalData.order_items" :key="item.id" class="flex justify-between text-[11px]">
              <span>{{ item.product_name }} x{{ item.quantity }}</span>
              <span>Rp {{ Number(item.subtotal).toLocaleString('id-ID') }}</span>
            </div>
          </div>
          <div class="border-t border-dashed pt-2 space-y-1 text-[11px]">
            <div class="flex justify-between"><span>Subtotal Sewa:</span><span>Rp {{ Number(receiptModalData.total_price || 0).toLocaleString('id-ID') }}</span></div>
            <div v-if="Number(receiptModalData.late_fee || 0) > 0" class="flex justify-between"><span>Denda Keterlambatan:</span><span>Rp {{ Number(receiptModalData.late_fee).toLocaleString('id-ID') }}</span></div>
            <div v-if="Number(receiptModalData.damage_fee || 0) > 0" class="flex justify-between"><span>Denda Kerusakan/Hilang:</span><span>Rp {{ Number(receiptModalData.damage_fee).toLocaleString('id-ID') }}</span></div>
          </div>
          <div class="flex justify-between text-sm font-bold pt-1">
            <span>TOTAL AKHIR:</span>
            <span class="text-emerald-700">Rp {{ (Number(receiptModalData.total_price || 0) + Number(receiptModalData.late_fee || 0) + Number(receiptModalData.damage_fee || 0)).toLocaleString('id-ID') }}</span>
          </div>
        </div>

        <div class="space-y-2 pt-2 border-t print:hidden">
          <button @click="sendWhatsAppNota(receiptModalData)" class="w-full bg-emerald-600 text-white font-bold py-2 rounded-lg text-xs">📲 Kirim Nota via WA</button>
          <div class="flex gap-2">
            <button @click="printReceipt" class="flex-1 bg-slate-800 text-white font-semibold py-2 rounded-lg text-xs">🖨️ Cetak Nota</button>
            <button @click="receiptModalData = null" class="bg-slate-200 text-slate-700 font-semibold px-4 py-2 rounded-lg text-xs">Tutup</button>
          </div>
        </div>
      </div>
    </div>

    <footer v-if="currentPOV === 'customer'" class="mt-12 bg-emerald-950 text-white print:hidden">
      <div class="max-w-7xl mx-auto px-4 py-8 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
        <div class="flex items-center gap-3">
          <img src="/logo-jabal.png" alt="Logo Jabal Outdoor" class="w-12 h-12 rounded-lg object-cover" />
          <div>
            <p class="font-black tracking-wide text-sm">JABAL OUTDOOR</p>
            <p class="text-[11px] text-emerald-200">Teman perjalanan outdoor kamu</p>
          </div>
        </div>

        <div class="text-xs text-emerald-100 space-y-2">
          <h3 class="font-bold text-sm text-white">Informasi Lokasi & Kontak</h3>
          <p><span class="font-semibold text-white">Alamat:</span> Kp. Panyairan RT 01/05, Desa Karyawangi, Kec. Parongpong, Kabupaten Bandung Barat, Jawa Barat 40559.</p>
          <a href="https://wa.me/6289517829189" target="_blank" rel="noopener noreferrer" class="block hover:text-white transition">
            <span class="font-semibold text-white">No. Telepon / WhatsApp:</span> 0895-1782-9189
          </a>
        </div>

        <div class="text-xs text-emerald-100 space-y-2">
          <h3 class="font-bold text-sm text-white">Jam Buka</h3>
          <p>Senin - Kamis: 07.00 - 19.00 WIB</p>
          <p>Jumat: 13.00 - 20.00 WIB</p>
          <p>Sabtu - Minggu: 07.00 - 20.00 WIB</p>
        </div>
      </div>
    </footer>

  </div>
</template>

<style>
@keyframes splash-logo-in {
  0% { opacity: 0; transform: scale(0.7); }
  70% { opacity: 1; transform: scale(1.05); }
  100% { transform: scale(1); }
}

@keyframes splash-content-in {
  0% { opacity: 0; transform: translateY(14px); }
  100% { opacity: 1; transform: translateY(0); }
}

@keyframes splash-spin {
  to { transform: rotate(360deg); }
}

.splash-logo {
  animation: splash-logo-in 900ms cubic-bezier(0.22, 1, 0.36, 1) both;
}

.splash-logo img {
  opacity: 0.72;
  mix-blend-mode: luminosity;
  filter: saturate(0.72) sepia(0.12);
}

.splash-title,
.splash-tagline {
  animation: splash-content-in 700ms ease-out 250ms both;
}

.splash-loading {
  animation: splash-content-in 700ms ease-out 500ms both;
}

.splash-spinner {
  animation: splash-spin 800ms linear infinite;
}
</style>