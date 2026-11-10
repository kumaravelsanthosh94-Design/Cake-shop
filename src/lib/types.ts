export type CakeVariant = { label: string; price: number; unit: string };

export type Product = {
  id: string;
  name: string;
  category: string;
  description: string;
  image_url: string | null;
  ingredients: string[];
  allergens: string[];
  flavours: string[];
  variants: CakeVariant[];
  lead_days: number;
  is_available: boolean;
};

export type CartItem = {
  product: Product;
  variant: CakeVariant;
  flavour: string;
  quantity: number;
};

export type OrderItem = {
  id: string;
  product_name: string;
  variant_label: string;
  flavour: string;
  unit_price: number;
  quantity: number;
  line_total: number;
};

export type OrderEvent = {
  id: string;
  status: OrderStatus;
  note: string | null;
  created_at: string;
};

export type OrderStatus =
  | "requested"
  | "accepted"
  | "payment_received"
  | "baking"
  | "ready"
  | "out_for_delivery"
  | "delivered"
  | "declined";

export type Order = {
  id: string;
  order_number: string;
  customer_name: string;
  customer_phone: string;
  delivery_address: string;
  requested_for: string | null;
  delivery_preference: string;
  subtotal: number;
  delivery_fee: number | null;
  total: number | null;
  confirmed_slot: string | null;
  delivery_note: string | null;
  status: OrderStatus;
  is_paid: boolean;
  tracking_token?: string;
  items: OrderItem[];
  events: OrderEvent[];
  created_at: string;
};

export type StoreSettings = {
  bakery_name: string;
  tagline: string;
  phone: string;
  whatsapp_number: string;
  upi_id: string;
  delivery_area: string;
  hero_image_url: string;
  owner_id: string | null;
};

export const STATUS_LABELS: Record<OrderStatus, string> = {
  requested: "Order request received",
  accepted: "Order accepted",
  payment_received: "Payment received",
  baking: "Baking started",
  ready: "Cake ready for delivery",
  out_for_delivery: "Out for delivery",
  delivered: "Delivered",
  declined: "Order declined",
};

export const CUSTOMER_STAGES: OrderStatus[] = [
  "requested",
  "accepted",
  "payment_received",
  "baking",
  "ready",
  "out_for_delivery",
  "delivered",
];
